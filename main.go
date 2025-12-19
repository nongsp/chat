package main

import (
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"sync"

	"github.com/google/uuid"
	"github.com/gorilla/websocket"
)

var (
	upgrader = websocket.Upgrader{
		CheckOrigin: func(r *http.Request) bool { return true },
	}
	clients   = make(map[string]*websocket.Conn)
	clientsMu sync.Mutex
)

type Message struct {
	Type    string `json:"type"`
	Sender  string `json:"sender"`
	Content string `json:"content"`
}

func main() {
	os.MkdirAll("./uploads", os.ModePerm)

	http.HandleFunc("/ws", handleConnections)
	http.HandleFunc("/upload", handleUpload)
	http.Handle("/", http.FileServer(http.Dir("./static")))
	http.Handle("/uploads/", http.StripPrefix("/uploads/", http.FileServer(http.Dir("./uploads"))))

	port := "8080"
	fmt.Printf("✅ 服务器运行在 :%s (ARM64 兼容)\n", port)
	log.Fatal(http.ListenAndServe(":"+port, nil))
}

func handleConnections(w http.ResponseWriter, r *http.Request) {
	ws, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	defer ws.Close()

	userID := r.URL.Query().Get("id")
	clientsMu.Lock()
	clients[userID] = ws
	clientsMu.Unlock()

	for {
		var msg Message
		err := ws.ReadJSON(&msg)
		if err != nil {
			clientsMu.Lock()
			delete(clients, userID)
			clientsMu.Unlock()
			break
		}
		broadcast(msg)
	}
}

func broadcast(msg Message) {
	clientsMu.Lock()
	defer clientsMu.Unlock()
	for id, client := range clients {
		err := client.WriteJSON(msg)
		if err != nil {
			client.Close()
			delete(clients, id)
		}
	}
}

func handleUpload(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		return
	}
	file, header, err := r.FormFile("file")
	if err != nil {
		http.Error(w, err.Error(), 400)
		return
	}
	defer file.Close()

	fileName := uuid.New().String() + filepath.Ext(header.Filename)
	filePath := filepath.Join("./uploads", fileName)

	out, err := os.Create(filePath)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	defer out.Close()
	io.Copy(out, file)

	fmt.Fprintf(w, "/uploads/%s", fileName)
}
