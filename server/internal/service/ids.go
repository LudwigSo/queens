package service

import "github.com/google/uuid"

func uuidNew() string { return uuid.NewString() }
