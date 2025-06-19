-- PostgreSQL initialization script for Arbor development
-- This script sets up the basic database structure

-- Create extensions if needed
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_stat_statements";

-- Create schemas for different Arbor components
CREATE SCHEMA IF NOT EXISTS arbor_contracts;
CREATE SCHEMA IF NOT EXISTS arbor_security;
CREATE SCHEMA IF NOT EXISTS arbor_persistence;
CREATE SCHEMA IF NOT EXISTS arbor_core;

-- Grant permissions
GRANT ALL PRIVILEGES ON SCHEMA arbor_contracts TO arbor;
GRANT ALL PRIVILEGES ON SCHEMA arbor_security TO arbor;
GRANT ALL PRIVILEGES ON SCHEMA arbor_persistence TO arbor;
GRANT ALL PRIVILEGES ON SCHEMA arbor_core TO arbor;

-- Set search path
ALTER USER arbor SET search_path TO arbor_core,arbor_persistence,arbor_security,arbor_contracts,public;

-- Create a simple health check table
CREATE TABLE IF NOT EXISTS health_check (
    id SERIAL PRIMARY KEY,
    timestamp TIMESTAMP DEFAULT NOW(),
    status TEXT DEFAULT 'ok'
);

INSERT INTO health_check (status) VALUES ('initialized');

-- Log initialization
DO $$
BEGIN
    RAISE NOTICE 'Arbor database initialized successfully at %', NOW();
END $$;