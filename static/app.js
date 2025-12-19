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
