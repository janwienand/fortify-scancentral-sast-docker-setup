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

Falls deine SSC-Instanz nicht auf dem gleichen Docker-Netzwerk läuft, passe die `SCANCENTRAL_SSC_URL` in der `.env` an.

### 3. Fortify-Lizenz ablegen

```bash
cp /pfad/zu/fortify.license volumes/secrets/fortify.license
```

### 4. Auth-Token generieren

Dieses Token wird zwischen SSC, Controller und Worker geteilt:

```bash
openssl rand -hex 32 > volumes/secrets/scancentral-authtoken
```

### 5. HTTPS-Zertifikat erstellen

```bash
# Zufälliges Passwort generieren
KEYSTORE_PASSWORD=$(openssl rand -base64 24)
echo -n "$KEYSTORE_PASSWORD" > volumes/secrets/keystore_password

# Keystore für den Controller
keytool -genkeypair \
    -alias scancentral \
    -keyalg RSA -keysize 2048 -validity 365 \
    -storetype PKCS12 \
    -keystore volumes/secrets/scancentral-keystore.pfx \
    -storepass "$KEYSTORE_PASSWORD" \
    -dname "CN=sast-ctrl, OU=Fortify, O=OpenText" \
    -ext "SAN=DNS:sast-ctrl,DNS:localhost,IP:127.0.0.1"

# Zertifikat exportieren und Truststore für den Worker erstellen
keytool -exportcert \
    -alias scancentral \
    -keystore volumes/secrets/scancentral-keystore.pfx \
    -storepass "$KEYSTORE_PASSWORD" \
    -file /tmp/scancentral-cert.pem -rfc

TRUSTSTORE_PASSWORD=$(openssl rand -base64 24)
echo -n "$TRUSTSTORE_PASSWORD" > volumes/secrets/truststore_password

keytool -importcert \
    -alias scancentral \
    -file /tmp/scancentral-cert.pem \
    -keystore volumes/secrets/scancentral-truststore.jks \
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

### 8. ScanCentral SAST in SSC aktivieren

1. Öffne die SSC-Administration: **https://localhost:8443**
2. Gehe zu **Administration → Configuration → ScanCentral SAST**
3. Aktiviere ScanCentral SAST
4. Trage die Controller-URL ein: `https://sast-ctrl:8443/scancentral-ctrl`
5. Trage das Auth-Token ein (Inhalt von `volumes/secrets/scancentral-authtoken`)

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
├── .env.example              # Konfigurationsvorlage
├── .gitignore
├── docker-compose.yml        # Container-Definition
├── README.md
├── setup.sh                  # Automatisches Setup-Skript
└── volumes/
    ├── data/                 # Persistente Daten (wird erstellt)
    └── secrets/
        ├── fortify.license           # ← Hier ablegen
        ├── scancentral-authtoken     # Auth-Token (generiert)
        ├── scancentral-keystore.pfx  # HTTPS-Keystore (generiert)
        ├── scancentral-truststore.jks # Truststore für Worker (generiert)
        ├── keystore_password         # Keystore-Passwort (generiert)
        └── truststore_password       # Truststore-Passwort (generiert)
```

## Fehlerbehebung

| Problem | Lösung |
|---|---|
| `image not found` | `docker login` ausführen – dein Account braucht Zugriff auf `fortifydocker` |
| Controller startet nicht | Prüfe die Logs: `docker compose logs sast-ctrl` |
| Worker verbindet sich nicht | Prüfe ob Auth-Token in SSC und `.env` übereinstimmen |
| DB-Migration schlägt fehl | `volumes/data` Verzeichnis löschen und neu starten |
| SSC nicht erreichbar | Stelle sicher, dass SSC im selben Docker-Netzwerk (`fortify`) läuft |
| Netzwerk existiert nicht | `docker network create fortify` ausführen |
