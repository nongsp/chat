package main

import (
	"database/sql"
	"encoding/json"
	"log"
	"net/http"
	"os"
	"sync"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
	"github.com/gorilla/websocket"
	_ "github.com/lib/pq" // 导入驱动
	"golang.org/x/crypto/bcrypt"
)

// --- 配置文件与全局变量 ---
var (
	db           *sql.DB
	jwtKey       = []byte("your_secret_key") // 生产环境请使用环境变量
	upgrader     = websocket.Upgrader{CheckOrigin: func(r *http.Request) bool { return true }}
	clients      = make(map[int]*websocket.Conn) // userID -> connection
	clientsMu    sync.Mutex
)

// --- 数据模型 ---
type User struct {
	ID       int    `json:"id"`
	Username string `json:"username"`
	Password string `json:"password"`
}

type Message struct {
	ID         string    `json:"id"`
	SenderID   int       `json:"sender_id"`
	ReceiverID int       `json:"receiver_id"`
	Content    string    `json:"content"`
	Type       string    `json:"type"` // text, image, audio
	ReplyTo    string    `json:"reply_to,omitempty"`
	IsRead     bool      `json:"is_read"`
	CreatedAt  time.Time `json:"created_at"`
}

// --- 数据库初始化 ---
func initDB() {
	var err error
	dsn := os.Getenv("DB_URL") // e.g., "postgres://user:pass@db:5432/chatdb?sslmode=disable"
	db, err = sql.Open("postgres", dsn)
	if err != nil {
		log.Fatal(err)
	}

	// 创建表结构（生产环境建议使用迁移工具）
	schemas := []string{
		`CREATE TABLE IF NOT EXISTS users (id SERIAL PRIMARY KEY, username TEXT UNIQUE, password TEXT);`,
		`CREATE TABLE IF NOT EXISTS messages (
			id UUID PRIMARY KEY, 
			sender_id INT, 
			receiver_id INT, 
			content TEXT, 
			type TEXT, 
			reply_to UUID, 
			is_read BOOLEAN DEFAULT FALSE, 
			created_at TIMESTAMP DEFAULT NOW()
		);`,
	}
	for _, s := range schemas {
		if _, err := db.Exec(s); err != nil {
			log.Fatal(err)
		}
	}
}

// --- 鉴权中间件 ---
func generateToken(userID int) (string, error) {
	token := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.MapClaims{
		"user_id": userID,
		"exp":     time.Now().Add(time.Hour * 72).Unix(),
	})
	return token.SignedString(jwtKey)
}

// --- 业务处理函数 ---

// 注册
func handleRegister(w http.ResponseWriter, r *http.Request) {
	var u User
	json.NewDecoder(r.Body).Decode(&u)
	hash, _ := bcrypt.GenerateFromPassword([]byte(u.Password), bcrypt.DefaultCost)
	_, err := db.Exec("INSERT INTO users (username, password) VALUES ($1, $2)", u.Username, string(hash))
	if err != nil {
		http.Error(w, "用户已存在", 400)
		return
	}
	w.WriteHeader(http.StatusCreated)
}

// 登录
func handleLogin(w http.ResponseWriter, r *http.Request) {
	var u User
	json.NewDecoder(r.Body).Decode(&u)
	var dbUser User
	err := db.QueryRow("SELECT id, password FROM users WHERE username=$1", u.Username).Scan(&dbUser.ID, &dbUser.Password)
	if err != nil || bcrypt.CompareHashAndPassword([]byte(dbUser.Password), []byte(u.Password)) != nil {
		http.Error(w, "账号或密码错误", 401)
		return
	}
	token, _ := generateToken(dbUser.ID)
	json.NewEncoder(w).Encode(map[string]interface{}{"token": token, "user_id": dbUser.ID})
}

// WebSocket 处理 (带 JWT 验证)
func handleConnections(w http.ResponseWriter, r *http.Request) {
	tokenStr := r.URL.Query().Get("token")
	token, _ := jwt.Parse(tokenStr, func(t *jwt.Token) (interface{}, error) { return jwtKey, nil })
	
	claims, ok := token.Claims.(jwt.MapClaims)
	if !ok || !token.Valid {
		http.Error(w, "未授权", 401)
		return
	}
	userID := int(claims["user_id"].(float64))

	ws, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	defer ws.Close()

	clientsMu.Lock()
	clients[userID] = ws
	clientsMu.Unlock()

	// 1. 上线立即拉取离线消息
	pushOfflineMessages(userID, ws)

	// 2. 循环处理新消息
	for {
		var msg Message
		if err := ws.ReadJSON(&msg); err != nil {
			clientsMu.Lock()
			delete(clients, userID)
			clientsMu.Unlock()
			break
		}
		msg.ID = uuid.New().String()
		msg.SenderID = userID
		msg.CreatedAt = time.Now()

		// 存入数据库
		saveMessageToDB(msg)

		// 尝试实时转发
		forwardMessage(msg)
	}
}

func saveMessageToDB(m Message) {
	_, err := db.Exec(`INSERT INTO messages (id, sender_id, receiver_id, content, type, reply_to) 
		VALUES ($1, $2, $3, $4, $5, $6)`, m.ID, m.SenderID, m.ReceiverID, m.Content, m.Type, m.ReplyTo)
	if err != nil {
		log.Println("DB Save Error:", err)
	}
}

func forwardMessage(m Message) {
	clientsMu.Lock()
	targetWs, online := clients[m.ReceiverID]
	clientsMu.Unlock()

	if online {
		targetWs.WriteJSON(m)
	}
}

func pushOfflineMessages(userID int, ws *websocket.Conn) {
	rows, _ := db.Query("SELECT id, sender_id, content, type, created_at FROM messages WHERE receiver_id=$1 AND is_read=FALSE ORDER BY created_at ASC", userID)
	defer rows.Close()

	for rows.Next() {
		var m Message
		rows.Scan(&m.ID, &m.SenderID, &m.Content, &m.Type, &m.CreatedAt)
		m.ReceiverID = userID
		ws.WriteJSON(m)
		// 标记为已读 (简单逻辑：推送到前端就算已读，或由前端反馈 Ack)
		db.Exec("UPDATE messages SET is_read=TRUE WHERE id=$1", m.ID)
	}
}

func main() {
	initDB()
	
	http.HandleFunc("/register", handleRegister)
	http.HandleFunc("/login", handleLogin)
	http.HandleFunc("/ws", handleConnections)
	
	// 文件上传和静态服务保持不变...
	log.Println("Server with DB running on :8080")
	http.ListenAndServe(":8080", nil)
}