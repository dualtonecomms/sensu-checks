#!/bin/bash

# The URL to be checked
URL="https://localhost:3000/api/v1/test"

# Use curl to fetch the data from the URL, -k allows connections to SSL sites without certs
response=$(curl -k -s "$URL")

# The expected response
expected_response='{"authenticated":false}'

# Check if the response matches the expected response
if echo "$response" | grep -q "^$expected_response$"; then
    echo "The DTV API is running."
        exit 0
else
    echo "The DTV API is not returning the expected output."
        exit 2
fi