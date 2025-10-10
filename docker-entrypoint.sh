#!/bin/bash
set -e

echo "🚀 Step 1: Running data_loader..."
python ./src/app/components/data_loader.py

echo "✅ Data loaded successfully. Starting main application..."
python ./src/app/application.py