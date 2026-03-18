# Fortify ScanCentral SAST – Docker Setup

Docker Compose Setup für **Fortify ScanCentral SAST 25.4** (Controller + Worker).

> **Hinweis:** Dieses Setup ist für Evaluierungs- und PoC-Zwecke gedacht, nicht für den Produktionsbetrieb.

## Voraussetzungen

| Voraussetzung | Details |
|---|---|
| **Docker Desktop** | Version 24.0+ |
| **JDK** | 17+ (für `keytool` zur Zertifikat-Generierung) |
| **Fortify-Lizenz** | Gültige Fortify 25.x Lizenzdatei |
| **Docker Hub Zugang** | Zugriff auf die privaten `fortifydocker` Repositories |
| **Fortify SSC** | Laufende SSC-Instanz (z.B. über [fortify-ssc-docker-setup](https://github.com/janwienand/fortify-ssc-docker-setup)) |

### Systemanforderungen

| | Minimum | Empfohlen |
|---|---|---|
| **RAM** | 8 GB | 16 GB |
| **CPU** | 4 Kerne | 8 Kerne |
| **Festplatte** | 10 GB | 20 GB |

## Quick Start

```bash
# 1. Repository klonen
git clone https://github.com/janwienand/fortify-scancentral-sast-docker-setup.git
cd fortify-scancentral-sast-docker-setup

# 2. Fortify-Lizenz ablegen
cp /pfad/zu/fortify.license volumes/secrets/fortify.license

# 3. Bei Docker Hub einloggen (Zugriff auf fortifydocker erforderlich)
docker login

# 4. Setup-Skript ausführen
./setup.sh
```

Das Setup-Skript führt automatisch durch alle Schritte: Konfiguration erstellen, Auth-Token generieren, HTTPS-Zertifikate erstellen, Images pullen und Container starten.

## Manuelle Installation (Schritt für Schritt)

### 1. Repository klonen

```bash
git clone https://github.com/janwienand/fortify-scancentral-sast-docker-setup.git
cd fortify-scancentral-sast-docker-setup
```

### 2. Konfiguration erstellen

```bash
cp .env.example .env
```

Falls deine SSC-Instanz nicht auf dem gleichen Docker-Netzwerk läuft, passe `SCANCENTRAL_CONFIG_SSC_URL` in der `.env` an.

**Wichtig:** Der `DOCKER_NETWORK_NAME` muss mit dem Netzwerk übereinstimmen, in dem SSC läuft. Prüfe das mit:

```bash
docker network ls | grep fortify
```

### 3. Fortify-Lizenz ablegen

```bash
cp /pfad/zu/fortify.license volumes/secrets/fortify.license
```

### 4. Auth-Token generieren

Das gleiche Token wird für Worker, Client und SSC-Secret verwendet:

```bash
AUTH_TOKEN=$(openssl rand -hex 32)
echo -n "$AUTH_TOKEN" > volumes/secrets/scancentral-worker-auth-token
echo -n "$AUTH_TOKEN" > volumes/secrets/scancentral-client-auth-token
echo -n "$AUTH_TOKEN" > volumes/secrets/scancentral-ssc-scancentral-ctrl-secret
```

### 5. HTTPS-Zertifikat erstellen

```bash
# Zufälliges Passwort generieren
KEYSTORE_PASSWORD=$(openssl rand -base64 24)
echo -n "$KEYSTORE_PASSWORD" > volumes/secrets/keystore_password

# JKS Keystore für den Controller
keytool -genkeypair \
    -alias scancentral \
    -keyalg RSA -keysize 2048 -validity 365 \
    -storetype JKS \
    -keystore volumes/secrets/httpKeystore.jks \
    -storepass "$KEYSTORE_PASSWORD" -keypass "$KEYSTORE_PASSWORD" \
    -dname "CN=sast-ctrl, OU=Fortify, O=OpenText" \
    -ext "SAN=DNS:sast-ctrl,DNS:localhost,IP:127.0.0.1"

# Zertifikat exportieren und Truststore für den Worker erstellen
keytool -exportcert \
    -alias scancentral \
    -keystore volumes/secrets/httpKeystore.jks \
    -storepass "$KEYSTORE_PASSWORD" \
    -file /tmp/scancentral-cert.pem -rfc

TRUSTSTORE_PASSWORD=$(openssl rand -base64 24)
echo -n "$TRUSTSTORE_PASSWORD" > volumes/secrets/truststore_password

keytool -importcert \
    -alias scancentral \
    -file /tmp/scancentral-cert.pem \
    -keystore volumes/secrets/truststore.jks \
    -storepass "$TRUSTSTORE_PASSWORD" -noprompt

rm /tmp/scancentral-cert.pem
```

### 6. Verzeichnisse und Berechtigungen

```bash
mkdir -p volumes/data

# Nur auf Linux: Berechtigungen für Container-User setzen
sudo chown -R 1111:1111 volumes/data volumes/secrets
sudo chmod -R 770 volumes/data volumes/secrets
```

### 7. Docker-Netzwerk und Container starten

```bash
# Netzwerk erstellen (falls es nicht bereits von SSC erstellt wurde)
docker network create fortify

# Bei Docker Hub einloggen
docker login

# Container starten
docker compose up -d
```

### 8. SSC Truststore konfigurieren (wichtig!)

Da der ScanCentral SAST Controller ein selbstsigniertes Zertifikat verwendet, muss SSC diesem Zertifikat vertrauen. Dafür wird ein JVM Truststore benötigt:

```bash
# Controller-Zertifikat exportieren
CTRL_KEYSTORE_PW=$(cat volumes/secrets/keystore_password)
keytool -exportcert -alias scancentral \
    -keystore volumes/secrets/httpKeystore.jks \
    -storepass "$CTRL_KEYSTORE_PW" \
    -file /tmp/scancentral-ctrl-cert.pem -rfc

# Zertifikat in den SSC-Truststore importieren
# (den Pfad zum SSC-Secrets-Verzeichnis entsprechend anpassen)
SSC_SECRETS=../fortify-ssc-docker-setup/ssc-webapp/secrets
keytool -importcert -alias scancentral-ctrl \
    -file /tmp/scancentral-ctrl-cert.pem \
    -keystore "$SSC_SECRETS/truststore.jks" \
    -storepass changeit -noprompt

echo -n "changeit" > "$SSC_SECRETS/truststore_password"
rm /tmp/scancentral-ctrl-cert.pem
```

Dann in der SSC `docker-compose.yml` die Truststore-Umgebungsvariablen ergänzen:

```yaml
environment:
  JVM_TRUSTSTORE_FILE: /app/secrets/truststore.jks
  JVM_TRUSTSTORE_PASSWORD_FILE: /app/secrets/truststore_password
```

Anschließend SSC neu starten:

```bash
cd ../fortify-ssc-docker-setup
docker compose up -d
```

### 9. ScanCentral SAST in SSC aktivieren

Nach dem Start der Container muss ScanCentral SAST in der SSC-Administration konfiguriert werden.

**Schritt 1:** Öffne SSC im Browser unter **https://localhost:8443** und navigiere zu **Administration → Configuration → ScanCentral SAST**:

![ScanCentral SAST Konfiguration](docs/images/ssc-scancentral-sast-config.png)

**Schritt 2:** Aktiviere **Enable ScanCentral SAST** und trage folgende Werte ein:

| Feld | Wert |
|---|---|
| **ScanCentral Controller URL** | `https://sast-ctrl:8443/scancentral-ctrl` |
| **SSC and ScanCentral Controller shared secret** | Inhalt von `volumes/secrets/scancentral-ssc-scancentral-ctrl-secret` |

![ScanCentral SAST Konfiguration ausgefüllt](docs/images/ssc-scancentral-sast-config-filled.png)

Die Token-Werte kannst du mit folgendem Befehl auslesen:

```bash
cat volumes/secrets/scancentral-ssc-scancentral-ctrl-secret
```

Klicke auf **Save**.

**Schritt 3: SSC neu starten (wichtig!)**

Die Änderungen werden erst nach einem Neustart des SSC-Servers wirksam:

```bash
cd ../fortify-ssc-docker-setup
docker compose restart ssc-webapp
```

**Schritt 4:** Nach dem Restart erscheint der **ScanCentral**-Tab in der oberen Navigation:

![ScanCentral Tab](docs/images/ssc-scancentral-tab.png)

Unter **ScanCentral** sollten jetzt der Controller und der Worker als **Active** angezeigt werden.

## Architektur

```
┌─────────────────────────────────────────────────────┐
│                  Docker Network: fortify             │
│                                                      │
│  ┌──────────┐    ┌──────────────┐    ┌────────────┐ │
│  │   SSC    │◄───│  Controller  │◄───│   Worker   │ │
│  │  :8443   │    │    :9443     │    │            │ │
│  └──────────┘    └──────────────┘    └────────────┘ │
│                         ▲                            │
│                    ┌────┴─────┐                      │
│                    │ DB-Migr. │                      │
│                    │ (einmal) │                      │
│                    └──────────┘                      │
└─────────────────────────────────────────────────────┘
```

- **Controller** – Verwaltet Scan-Jobs und verteilt sie an Worker
- **Worker (Sensor)** – Führt die eigentlichen SAST-Scans durch
- **DB-Migration** – Initialisiert die eingebettete H2-Datenbank (läuft nur beim ersten Start)

## Nützliche Befehle

```bash
# Logs anzeigen
docker compose logs -f

# Nur Controller-Logs
docker compose logs -f sast-ctrl

# Nur Worker-Logs
docker compose logs -f sast-worker

# Container stoppen
docker compose down

# Container neu starten
docker compose down && docker compose up -d

# In den Controller-Container verbinden
docker compose exec sast-ctrl bash

# Status prüfen
docker compose ps
```

## Dateistruktur

```
fortify-scancentral-sast-docker-setup/
├── .env.example                      # Konfigurationsvorlage
├── .gitignore
├── docker-compose.yml                # Container-Definition
├── README.md
├── setup.sh                          # Automatisches Setup-Skript
└── volumes/
    ├── data/                         # Persistente Daten (wird erstellt)
    └── secrets/
        ├── fortify.license                          # ← Hier ablegen
        ├── scancentral-worker-auth-token            # Worker Auth-Token (generiert)
        ├── scancentral-client-auth-token            # Client Auth-Token (generiert)
        ├── scancentral-ssc-scancentral-ctrl-secret  # SSC Shared Secret (generiert)
        ├── httpKeystore.jks                         # HTTPS-Keystore (generiert)
        ├── truststore.jks                           # Truststore für Worker (generiert)
        ├── keystore_password                        # Keystore-Passwort (generiert)
        └── truststore_password                      # Truststore-Passwort (generiert)
```

## Fehlerbehebung

| Problem | Lösung |
|---|---|
| `image not found` | `docker login` ausführen – dein Account braucht Zugriff auf `fortifydocker` |
| `SCANCENTRAL_CONFIG_SSC_URL is required` | `.env` Datei prüfen – `SCANCENTRAL_CONFIG_SSC_URL` muss gesetzt sein |
| `SCANCENTRAL_URL environment variable is required` | `.env` Datei prüfen – `SCANCENTRAL_URL` muss gesetzt sein |
| Controller startet nicht | Prüfe die Logs: `docker compose logs sast-ctrl` |
| Worker verbindet sich nicht | Auth-Token in SSC und in `volumes/secrets/` müssen übereinstimmen |
| DB-Migration schlägt fehl | `volumes/data` Verzeichnis löschen und neu starten |
| SSC nicht erreichbar | Stelle sicher, dass SSC im selben Docker-Netzwerk läuft (`docker network ls`) |
| Netzwerk existiert nicht | `docker network create fortify` ausführen |
| Platform-Warnung (linux/amd64) | Normal auf Apple Silicon (M1/M2/M3) – läuft über Rosetta-Emulation |
| Test Connection schlägt fehl | Prüfe ob Controller läuft (`docker compose ps`) und die URL korrekt ist |
