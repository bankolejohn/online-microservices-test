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

RUN apk --no-cache add ca-certificates && \
    adduser -D -u 1000 appuser

WORKDIR /app

# Copy the binary and make it executable by all
COPY --from=builder /app/main .
RUN chmod +x ./main

USER 1000

EXPOSE 8080

CMD ["./main"]
