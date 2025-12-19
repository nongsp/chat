let currentUser = null;
let token = null;
let ws = null;
let replyingToId = null; // 当前正在引用的消息ID

// 1. 登录与注册
async function handleAuth(type) {
    const u = document.getElementById('username').value;
    const p = document.getElementById('password').value;
    
    const res = await fetch(`/${type}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ username: u, password: p })
    });

    if (res.ok) {
        if (type === 'login') {
            const data = await res.json();
            token = data.token;
            currentUser = data.user_id;
            startChat();
        } else {
            alert("注册成功，请登录");
        }
    } else {
        alert("操作失败，请检查用户名或密码");
    }
}

// 2. 建立 WebSocket 连接
function startChat() {
    document.getElementById('auth-container').classList.add('hidden');
    document.getElementById('chat-container').classList.remove('hidden');

    ws = new WebSocket(`ws://${location.host}/ws?token=${token}`);

    ws.onmessage = (e) => {
        const msg = JSON.parse(e.data);
        renderMessage(msg);
        if (msg.sender_id !== currentUser) {
            document.getElementById('notifSound').play();
        }
    };

    ws.onclose = () => alert("连接已断开，请重新登录");
}

// 3. 渲染消息（含引用逻辑）
function renderMessage(msg) {
    const win = document.getElementById('chat-window');
    const wrapper = document.createElement('div');
    wrapper.className = 'msg-wrapper';
    
    const isMine = msg.sender_id === currentUser;
    let contentHtml = "";

    // 处理引用内容显示
    let quoteHtml = "";
    if (msg.reply_to) {
        quoteHtml = `<div class="quote-box">引用消息: ${msg.reply_to.substring(0,8)}...</div>`;
    }

    if (msg.type === 'text') {
        contentHtml = msg.content;
    } else if (msg.type === 'image') {
        contentHtml = `<img src="${msg.content}" style="max-width:100%">`;
    } else if (msg.type === 'audio') {
        contentHtml = `<div onclick="new Audio('${msg.content}').play()">🎵 语音消息</div>`;
    }

    wrapper.innerHTML = `
        <div style="font-size:10px; color:#999; align-self: ${isMine?'flex-end':'flex-start'}">用户ID: ${msg.sender_id}</div>
        <div class="msg-bubble ${isMine ? 'mine' : 'others'}" onclick="setReply('${msg.id}', '${msg.content}')">
            ${quoteHtml}
            ${contentHtml}
        </div>
    `;
    
    win.appendChild(wrapper);
    win.scrollTop = win.scrollHeight;
}

// 4. 发送逻辑
function sendText() {
    const input = document.getElementById('msgInput');
    const target = document.getElementById('targetId').value;
    if (!input.value || !target) return alert("请输入内容和目标ID");

    const msg = {
        type: 'text',
        receiver_id: parseInt(target),
        content: input.value,
        reply_to: replyingToId
    };

    ws.send(JSON.stringify(msg));
    input.value = "";
    cancelReply();
}

async function uploadFile() {
    const file = document.getElementById('fileInput').files[0];
    const target = document.getElementById('targetId').value;
    if (!file || !target) return;

    const formData = new FormData();
    formData.append('file', file);

    const res = await fetch('/upload', { method: 'POST', body: formData });
    const url = await res.text();

    const type = file.type.startsWith('image') ? 'image' : 'audio';
    ws.send(JSON.stringify({
        type: type,
        receiver_id: parseInt(target),
        content: url,
        reply_to: replyingToId
    }));
    cancelReply();
}

// 5. 引用功能交互
function setReply(id, text) {
    replyingToId = id;
    document.getElementById('reply-bar').classList.remove('hidden');
    document.getElementById('reply-text').innerText = "正在引用: " + text.substring(0, 15) + "...";
}

function cancelReply() {
    replyingToId = null;
    document.getElementById('reply-bar').classList.add('hidden');
}