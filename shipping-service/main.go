package main

import (
	"fmt"
	"math/rand"
	"net/http"
	"os"
	"strconv"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
)

type ShippingRequest struct {
	OrderID string                 `json:"orderId" binding:"required"`
	Items   []map[string]interface{} `json:"items" binding:"required"`
	Address Address                `json:"address" binding:"required"`
}

type Address struct {
	Street  string `json:"address" binding:"required"`
	City    string `json:"city" binding:"required"`
	ZipCode string `json:"zipCode" binding:"required"`
}

type ShippingResponse struct {
	ShippingID        string `json:"shippingId"`
	OrderID           string `json:"orderId"`
	TrackingNumber    string `json:"trackingNumber"`
	Status            string `json:"status"`
	EstimatedDelivery string `json:"estimatedDelivery"`
	Carrier           string `json:"carrier"`
	Message           string `json:"message"`
}

func main() {
	// Set Gin to release mode in production
	gin.SetMode(gin.ReleaseMode)
	
	r := gin.Default()

	// Health check endpoint
	r.GET("/health", func(c *gin.Context) {
		c.JSON(http.StatusOK, gin.H{
			"status":  "healthy",
			"service": "shipping-service",
		})
	})

	// Create shipping order
	r.POST("/api/shipping/create", createShippingOrder)

	// Get shipping status
	r.GET("/api/shipping/status/:trackingNumber", getShippingStatus)

	// Get port from environment or default to 8080
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	fmt.Printf("Shipping service running on port %s\n", port)
	r.Run(":" + port)
}

func createShippingOrder(c *gin.Context) {
	var req ShippingRequest
	
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "Invalid request data"})
		return
	}

	// Simulate processing delay
	time.Sleep(time.Duration(rand.Intn(2)+1) * time.Second)

	// Generate shipping details
	shippingID := uuid.New().String()
	trackingNumber := generateTrackingNumber()
	
	// Calculate estimated delivery (3-7 business days)
	deliveryDays := rand.Intn(5) + 3
	estimatedDelivery := time.Now().AddDate(0, 0, deliveryDays).Format("2006-01-02")
	
	// Random carrier selection
	carriers := []string{"FedEx", "UPS", "DHL", "USPS"}
	carrier := carriers[rand.Intn(len(carriers))]

	response := ShippingResponse{
		ShippingID:        shippingID,
		OrderID:           req.OrderID,
		TrackingNumber:    trackingNumber,
		Status:            "created",
		EstimatedDelivery: estimatedDelivery,
		Carrier:           carrier,
		Message:           "Shipping order created successfully",
	}

	c.JSON(http.StatusOK, response)
}

func getShippingStatus(c *gin.Context) {
	trackingNumber := c.Param("trackingNumber")
	
	if trackingNumber == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "Tracking number is required"})
		return
	}

	// Mock shipping statuses
	statuses := []string{"created", "picked_up", "in_transit", "out_for_delivery", "delivered"}
	status := statuses[rand.Intn(len(statuses))]
	
	// Mock location updates
	locations := []string{"Origin Facility", "Sorting Facility", "Transit Hub", "Local Facility", "Out for Delivery"}
	location := locations[rand.Intn(len(locations))]

	response := gin.H{
		"trackingNumber": trackingNumber,
		"status":         status,
		"location":       location,
		"lastUpdate":     time.Now().Format("2006-01-02T15:04:05Z"),
		"message":        fmt.Sprintf("Package is %s at %s", status, location),
	}

	c.JSON(http.StatusOK, response)
}

func generateTrackingNumber() string {
	// Generate a mock tracking number
	prefix := "SHP"
	number := rand.Intn(999999999) + 100000000
	return prefix + strconv.Itoa(number)
}