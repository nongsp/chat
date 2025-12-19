#!/bin/bash

echo "🚀 开始生成项目文件..."

# 创建目录结构
mkdir -p .github/workflows
mkdir -p static
mkdir -p uploads

# 1. 生成后端代码 main.go
cat << 'INNER_EOF' > main.go
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
INNER_EOF

# 2. 生成前端 HTML static/index.html
cat << 'INNER_EOF' > static/index.html
<!DOCTYPE html>
<html lang="zh">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>微信 Web 版</title>
    <style>
        body { font-family: sans-serif; background: #ebebeb; margin: 0; display: flex; flex-direction: column; height: 100vh; }
        #chat { flex: 1; overflow-y: auto; padding: 15px; }
        .msg-row { margin-bottom: 15px; display: flex; flex-direction: column; }
        .msg-content { background: white; padding: 8px 12px; border-radius: 5px; max-width: 70%; align-self: flex-start; box-shadow: 0 1px 2px rgba(0,0,0,0.1); }
        .mine { align-self: flex-end; background: #95ec69; }
        .sender-name { font-size: 12px; color: #888; margin-bottom: 4px; }
        .input-area { background: #f5f5f5; padding: 10px; display: flex; gap: 10px; border-top: 1px solid #ddd; }
        input[type="text"] { flex: 1; padding: 8px; border: 1px solid #ccc; border-radius: 4px; }
        button { padding: 8px 15px; background: #07c160; color: white; border: none; border-radius: 4px; cursor: pointer; }
        img { max-width: 200px; border-radius: 5px; }
        .audio-btn { cursor: pointer; color: #007bff; text-decoration: underline; }
    </style>
</head>
<body>
    <div id="chat"></div>
    <div class="input-area">
        <input type="text" id="textInput" placeholder="请输入消息...">
        <button onclick="sendText()">发送</button>
    </div>
    <div class="input-area" style="padding-top: 0;">
        <input type="file" id="fileInput">
        <button style="background: #28a745;" onclick="uploadFile()">发送图片/语音</button>
    </div>
    <audio id="notifSound" src="https://assets.mixkit.co/active_storage/sfx/2358/2358-preview.mp3"></audio>
    <script src="app.js"></script>
</body>
</html>
INNER_EOF

# 3. 生成前端 JS static/app.js
cat << 'INNER_EOF' > static/app.js
let userId = "用户" + Math.floor(Math.random() * 1000);
let ws = new WebSocket(`ws://${location.host}/ws?id=${userId}`);
let chat = document.getElementById("chat");
let notifSound = document.getElementById("notifSound");

ws.onmessage = (event) => {
    let msg = JSON.parse(event.data);
    appendMessage(msg);
    if (msg.sender !== userId) {
        notifSound.play().catch(() => console.log("等待用户交互后开启提示音"));
    }
};

function appendMessage(msg) {
    let row = document.createElement("div");
    row.className = "msg-row";
    let isMine = msg.sender === userId;
    
    let content = "";
    if (msg.type === "text") content = msg.content;
    else if (msg.type === "image") content = `<img src="${msg.content}">`;
    else if (msg.type === "audio") content = `<div class="audio-btn" onclick="new Audio('${msg.content}').play()">🎵 语音消息 (点击播放)</div>`;

    row.innerHTML = `
        <span class="sender-name" style="${isMine ? 'text-align:right' : ''}">${msg.sender}</span>
        <div class="msg-content ${isMine ? 'mine' : ''}">${content}</div>
    `;
    chat.appendChild(row);
    chat.scrollTop = chat.scrollHeight;
}

function sendText() {
    let input = document.getElementById("textInput");
    if (!input.value) return;
    ws.send(JSON.stringify({ type: "text", sender: userId, content: input.value }));
    input.value = "";
}

async function uploadFile() {
    let fileInput = document.getElementById("fileInput");
    if (!fileInput.files[0]) return;
    let formData = new FormData();
    formData.append("file", fileInput.files[0]);
    let res = await fetch("/upload", { method: "POST", body: formData });
    let url = await res.text();
    let type = fileInput.files[0].type.startsWith("image") ? "image" : "audio";
    ws.send(JSON.stringify({ type: type, sender: userId, content: url }));
}
INNER_EOF

# 4. 生成 Dockerfile
cat << 'INNER_EOF' > Dockerfile
FROM --platform=$BUILDPLATFORM golang:1.21-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
ARG TARGETOS TARGETARCH
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -o server main.go

FROM alpine:latest
WORKDIR /root/
COPY --from=builder /app/server .
COPY --from=builder /app/static ./static
RUN mkdir ./uploads
EXPOSE 8080
CMD ["./server"]
INNER_EOF

# 5. 生成 GitHub Actions 配置
cat << 'INNER_EOF' > .github/workflows/docker-publish.yml
name: Build and Push ARM64
on:
  push:
    branches: [ "main" ]
jobs:
  build:
    runs-on: ubuntu-latest
    permissions: { contents: read, packages: write }
    steps:
      - uses: actions/checkout@v3
      - uses: docker/setup-qemu-action@v2
      - uses: docker/setup-buildx-action@v2
      - uses: docker/login-action@v2
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - uses: docker/build-push-action@v4
        with:
          context: .
          platforms: linux/arm64
          push: true
          tags: ghcr.io/${{ github.repository }}:latest
INNER_EOF

# 6. 初始化 Go 依赖
go mod init mini-wechat
go get github.com/google/uuid
go get github.com/gorilla/websocket
go mod tidy

echo "✅ 项目创建完成！"
echo "👉 现在你可以执行以下命令上传到 GitHub:"
echo "   git init"
echo "   git add ."
echo "   git commit -m 'initial commit'"
echo "   git remote add origin <你的GitHub地址>"
echo "   git push -u origin main"
