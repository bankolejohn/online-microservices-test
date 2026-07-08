# Build stage
FROM golang:1.22-alpine AS builder

WORKDIR /app

# Copy everything needed for the build
COPY go.mod ./
COPY *.go ./

# Resolve dependencies and build
RUN go mod tidy && \
    go mod download && \
    CGO_ENABLED=0 GOOS=linux go build -a -installsuffix cgo -o main .

# Production stage
FROM alpine:latest

RUN apk --no-cache add ca-certificates
WORKDIR /root/

# Copy the binary from builder stage
COPY --from=builder /app/main .

EXPOSE 8080

CMD ["./main"]
