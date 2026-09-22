# Shipyard

> A lightweight self-hosted deployment platform for VPS-hosted applications.

Shipyard automates the repetitive parts of deploying applications to your own server. It creates projects, manages release-based deployments, generates Nginx configurations, keeps deployment history, and integrates seamlessly with GitHub Actions.

Whether you're hosting a personal portfolio, APIs, SaaS products, Docker applications, or internal tools, Shipyard provides a simple and consistent deployment workflow without relying on external platforms.

---

# Why Shipyard?

Deploying projects to a VPS often involves manually creating directories, writing Nginx configurations, uploading files, updating symlinks, and managing releases.

Shipyard turns that process into a single command.

Instead of:

- Creating project directories
- Writing Nginx configuration
- Enabling sites
- Uploading build artifacts
- Updating symlinks
- Remembering deployment commands

You simply run:

```bash
shipyard create portfolio --type static --domain example.com
```

or deploy a new release with:

```bash
shipyard deploy portfolio /tmp/portfolio.tar.gz <release-id>
```

---

# Features

- Release-based deployments
- Atomic symlink switching
- Rollback support
- Automatic Nginx configuration generation
- Multiple project types
  - Static
  - Laravel
  - Node
  - Docker
- Project configuration management
- Deployment status
- Health checks
- Deployment logs
- GitHub Actions friendly
- Modular architecture

---

# Architecture

```
Developer
   │
   ▼ Git Push
   │
   ▼ GitHub Actions
   │
   ▼ Build Artifact
   │
   ▼ Shipyard CLI
   │
   ├─ Release Manager
   ├─ Docker Compose (docker projects)
   └─ Nginx Generator
   │
   ▼ Production
```

Each deployment creates a new immutable release directory.

```
/var/www/sites/portfolio
├── current -> releases/8fa2d19
├── releases
│   ├── 4ab8321
│   ├── 6e019ba
│   └── 8fa2d19
└── shared
```

Deployments become atomic by updating the `current` symlink rather than replacing files in place.

For Docker projects, Nginx proxies public traffic to the application on a local port:

```
Internet → Nginx :80/:443 → 127.0.0.1:<DOCKER_PORT> → Docker application
```

---

# Installation

Clone the repository:

```bash
git clone https://github.com/<your-username>/shipyard.git
cd shipyard
```

Install Shipyard:

```bash
sudo ./install.sh
```

Verify your installation:

```bash
shipyard doctor
```

---

# Commands

## Create a project

```bash
shipyard create portfolio \
  --type static \
  --domain example.com
```

Supported project types:

- `static`
- `laravel`
- `node`
- `docker`

### Create a Docker project

```bash
shipyard create blog \
  --type docker \
  --domain blog.ali-wissam.com \
  --port 8080
```

Docker projects require the application repository to provide:

- `Dockerfile`
- `docker-compose.prod.yml` (or the file configured in the project)

The `--port` flag sets the host port Nginx proxies to (default: `8080`).

---

## Deploy a release

```bash
shipyard deploy portfolio \
  /tmp/portfolio.tar.gz \
  394bfe1004a96cf518b1832c7253a65978ad9914
```

For Docker projects, the artifact should contain the application source and Docker configuration:

```
release/
├── Dockerfile
├── docker-compose.prod.yml
├── .dockerignore
├── app/
└── ...
```

Shipyard extracts the artifact, starts Docker Compose from the new release directory, and only switches `current` after the deployment passes health checks:

```bash
docker compose -p shipyard-<project> -f docker-compose.prod.yml up -d --build
```

If the new release fails, Shipyard restores the previous Docker deployment and leaves `current` pointing at the last healthy release.

---

## Check project status

```bash
shipyard status portfolio
```

For Docker projects:

```bash
shipyard status blog
```

Example output:

```
Project : blog
Type    : docker
Domain  : blog.ali-wissam.com
Release : abc123
Docker:
  Compose project : shipyard-blog
  Status          : running
  Port            : 8080
  Health path     : /
  Health          : healthy
```

---

## Roll back

```bash
shipyard rollback portfolio
```

For Docker projects, rollback starts the previous release with Docker Compose, verifies it is healthy, and only then switches `current`. If rollback fails, Shipyard attempts to restore the currently working deployment.

---

## Regenerate Nginx configuration

```bash
shipyard nginx portfolio
```

---

## List projects

```bash
shipyard list
```

---

## Verify installation

```bash
shipyard doctor
```

---

# Project Types

| Type | Description |
|------|-------------|
| Static | Static websites (Astro, Vite, React build output, etc.) |
| Laravel | Laravel applications (foundation for future deployment hooks) |
| Node | Node.js applications (foundation for future deployment hooks) |
| Docker | Docker applications using Compose (PHP, Node, custom stacks, etc.) |

---

# Docker Projects

Shipyard orchestrates Docker deployments but does not generate Dockerfiles or application images. Your repository defines the container setup.

### Architecture

```
Shipyard
   ↓
Docker Compose (shipyard-<project>)
   ↓
127.0.0.1:<DOCKER_PORT>
   ↓
Nginx
   ↓
blog.ali-wissam.com
```

### Requirements

- `Dockerfile`
- `docker-compose.prod.yml` (default; configurable per project)
- Application exposed on the configured **host** port (default `8080`)

### Port mapping

`DOCKER_PORT` is the **host** port Shipyard and Nginx use. The container may listen on a different internal port.

Example Compose configuration:

```yaml
services:
  app:
    ports:
      - "127.0.0.1:8080:80"
```

Shipyard health checks and Nginx both communicate with `http://127.0.0.1:8080`. The application inside the container may listen on port `80`.

### Project configuration

```bash
TYPE=docker
DOMAIN=blog.ali-wissam.com
DOCKER_PORT=8080
DOCKER_COMPOSE_FILE=docker-compose.prod.yml
DOCKER_HEALTH_PATH=/
KEEP_RELEASES=5
```

`DOCKER_HEALTH_PATH` defaults to `/` and can be customized per project:

```bash
DOCKER_HEALTH_PATH=/health
```

Shipyard checks `http://127.0.0.1:<DOCKER_PORT><DOCKER_HEALTH_PATH>` and requires a successful HTTP response when `curl` is available.

### Environment variables

Shipyard does not commit or generate production secrets. Place persistent environment files on the server:

```
/var/www/sites/blog/shared/.env
```

During deployment, Shipyard links `shared/.env` into the active release without overwriting an existing production `.env` in the release directory.

### Persistent data

Docker volumes are managed by Docker Compose and survive normal deployments.

**Shipyard never runs `docker compose down -v` during deployment, rollback, or failure recovery.**

Release cleanup only removes old release directories. It does not remove Docker volumes or shared files.

### Transactional deployments

Docker deployments are transactional:

1. Extract and validate the new release
2. Start Docker Compose from the new release directory
3. Run health checks against the configured host port and path
4. Switch `current` only after the new release is healthy

If any step fails, Shipyard logs diagnostics, restores the previous Docker deployment when one exists, keeps `current` on the last healthy release, and removes only the failed release directory.

### Transactional rollback

Rollback follows the same principle:

1. Validate the previous release
2. Start Docker Compose for the previous release
3. Run health checks
4. Switch `current` only after the previous release is healthy

If rollback fails, Shipyard attempts to restore the currently working deployment and leaves `current` unchanged.

---

# GitHub Actions

Shipyard is designed to work with GitHub Actions.

A typical workflow:

1. Build the application.
2. Archive the build output.
3. Upload the artifact to the VPS.
4. Execute:

```bash
shipyard deploy <project> /tmp/artifact.tar.gz <release-id>
```

---

# Roadmap

Upcoming features include:

- HTTPS / Let's Encrypt integration
- Domain management
- Deployment hooks
- Laravel deployment pipeline
- Node.js service management
- Remote deployment monitoring
- Plugin support

---

# Contributing

Issues, feature requests, and pull requests are welcome.

If you find a bug or have an idea that improves Shipyard, feel free to open an issue or submit a pull request.

---

# License

This project is released under the MIT License.
