# 阶段1: 编译环境
FROM --platform=$BUILDPLATFORM golang:1.21-alpine AS builder
WORKDIR /app

# 设置 Go 代理（可选，但在某些环境下能大幅提高下载成功率）
ENV GOPROXY=https://proxy.golang.com.cn,direct

# 先复制依赖文件进行下载，利用 Docker 缓存层
COPY go.mod go.sum* ./
RUN go mod download

# 复制源码
COPY . .

# 编译
ARG TARGETOS TARGETARCH
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -o server main.go

FROM alpine:latest
WORKDIR /root/
COPY --from=builder /app/server .
COPY --from=builder /app/static ./static
RUN mkdir ./uploads
EXPOSE 8080
CMD ["./server"]
