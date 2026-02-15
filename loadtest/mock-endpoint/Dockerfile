FROM golang:1.22-alpine AS build
WORKDIR /app
COPY main.go .
RUN go build -o mock-endpoint main.go

FROM alpine:3.19
COPY --from=build /app/mock-endpoint /usr/local/bin/
EXPOSE 8080
CMD ["mock-endpoint"]
