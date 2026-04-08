# NSheep Makefile

.PHONY: all build release test clean install docker run dev

# Default target
all: build

# Build debug version
build:
	nim c -o:nsheep src/nsheep.nim

# Build release version
release:
	nim c -d:release -o:nsheep src/nsheep.nim

# Build with optimization
optimize:
	nim c -d:release -d:danger --opt:speed -o:nsheep src/nsheep.nim

# Run tests
test:
	nimble test

# Clean build artifacts
clean:
	rm -f nsheep
	rm -rf nimcache
	rm -rf dist

# Install dependencies
install:
	nimble install -y

# Run development server
dev:
	nim c -r -o:nsheep src/nsheep.nim

# Run with custom config
run:
	./nsheep --config config.json

# Build Docker image
docker:
	docker build -t nsheep:latest .

# Run with Docker Compose
docker-run:
	docker-compose up -d

# Stop Docker containers
docker-stop:
	docker-compose down

# Format code
fmt:
	nimpretty src/**/*.nim

# Lint code
lint:
	nim check src/nsheep.nim

# Generate documentation
docs:
	nim doc -o:docs/ src/nsheep.nim

# Create distribution
dist: release
	mkdir -p dist/nsheep
	cp nsheep dist/nsheep/
	cp config.json dist/nsheep/
	cp README.md dist/nsheep/
	cp LICENSE dist/nsheep/
	tar -czf dist/nsheep-$(shell uname -s)-$(shell uname -m).tar.gz -C dist nsheep

# Help
help:
	@echo "NSheep build targets:"
	@echo "  make build      - Build debug version"
	@echo "  make release    - Build release version"
	@echo "  make optimize   - Build with maximum optimization"
	@echo "  make test       - Run tests"
	@echo "  make clean      - Clean build artifacts"
	@echo "  make install    - Install dependencies"
	@echo "  make dev        - Run development server"
	@echo "  make run        - Run with config.json"
	@echo "  make docker     - Build Docker image"
	@echo "  make docker-run - Run with Docker Compose"
	@echo "  make dist       - Create distribution archive"
