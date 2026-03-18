#!/bin/bash
set -e

# =============================================================================
# Fortify ScanCentral SAST – Automatisches Setup
# =============================================================================

BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo ""
echo -e "${BOLD}=== Fortify ScanCentral SAST – Setup ===${NC}"
echo ""

# --- 1. Voraussetzungen prüfen ----------------------------------------------
echo -e "${BOLD}[1/8] Voraussetzungen prüfen...${NC}"

if ! command -v docker &>/dev/null; then
    echo -e "${RED}Docker ist nicht installiert. Bitte installiere Docker Desktop 24.0+.${NC}"
    exit 1
fi
echo "  ✓ Docker gefunden"

if docker compose version &>/dev/null; then
    COMPOSE_CMD="docker compose"
    echo "  ✓ Docker Compose gefunden"
elif command -v docker-compose &>/dev/null; then
    COMPOSE_CMD="docker-compose"
    echo "  ✓ docker-compose gefunden"
else
    echo -e "${RED}Docker Compose ist nicht installiert.${NC}"
    exit 1
fi

if ! command -v keytool &>/dev/null; then
    echo -e "${RED}keytool nicht gefunden. Bitte installiere ein JDK 17+.${NC}"
    exit 1
fi
echo "  ✓ keytool gefunden (JDK)"
echo ""

# --- 2. .env erstellen ------------------------------------------------------
echo -e "${BOLD}[2/8] Konfiguration erstellen...${NC}"
if [ ! -f .env ]; then
    cp .env.example .env
    echo "  ✓ .env aus .env.example erstellt"
else
    echo "  → .env existiert bereits, überspringe"
fi
echo ""

# --- 3. Lizenz prüfen -------------------------------------------------------
echo -e "${BOLD}[3/8] Fortify-Lizenz prüfen...${NC}"
LICENSE_FILE="volumes/secrets/fortify.license"
if [ ! -f "$LICENSE_FILE" ]; then
    echo -e "${YELLOW}  ⚠ Bitte kopiere deine Fortify-Lizenzdatei nach:${NC}"
    echo "    $LICENSE_FILE"
    echo ""
    read -p "  Fortify-Lizenz liegt bereit? (Enter zum Fortfahren, Ctrl+C zum Abbrechen) "
fi

if [ ! -f "$LICENSE_FILE" ]; then
    echo -e "${RED}  ✗ Lizenzdatei nicht gefunden: $LICENSE_FILE${NC}"
    exit 1
fi
echo "  ✓ Lizenzdatei gefunden"
echo ""

# --- 4. Auth-Token generieren -----------------------------------------------
echo -e "${BOLD}[4/8] Auth-Token generieren...${NC}"
AUTHTOKEN_FILE="volumes/secrets/scancentral-authtoken"
if [ ! -f "$AUTHTOKEN_FILE" ]; then
    openssl rand -hex 32 > "$AUTHTOKEN_FILE"
    echo "  ✓ Auth-Token generiert: $AUTHTOKEN_FILE"
    echo -e "${YELLOW}  ⚠ WICHTIG: Dieses Token muss auch in der SSC-Administration${NC}"
    echo -e "${YELLOW}    unter ScanCentral SAST eingetragen werden.${NC}"
else
    echo "  → Auth-Token existiert bereits, überspringe"
fi
echo ""

# --- 5. HTTPS-Zertifikat erstellen ------------------------------------------
echo -e "${BOLD}[5/8] HTTPS-Zertifikat für Controller erstellen...${NC}"
KEYSTORE_FILE="volumes/secrets/scancentral-keystore.pfx"
KEYSTORE_PW_FILE="volumes/secrets/keystore_password"
TRUSTSTORE_FILE="volumes/secrets/scancentral-truststore.jks"
TRUSTSTORE_PW_FILE="volumes/secrets/truststore_password"

if [ ! -f "$KEYSTORE_FILE" ]; then
    KEYSTORE_PASSWORD=$(openssl rand -base64 24)
    echo -n "$KEYSTORE_PASSWORD" > "$KEYSTORE_PW_FILE"

    keytool -genkeypair \
        -alias scancentral \
        -keyalg RSA \
        -keysize 2048 \
        -validity 365 \
        -storetype PKCS12 \
        -keystore "$KEYSTORE_FILE" \
        -storepass "$KEYSTORE_PASSWORD" \
        -dname "CN=sast-ctrl, OU=Fortify, O=OpenText, L=Munich, ST=Bavaria, C=DE" \
        -ext "SAN=DNS:sast-ctrl,DNS:localhost,IP:127.0.0.1" \
        2>/dev/null

    echo "  ✓ Keystore erstellt: $KEYSTORE_FILE"

    # Truststore für Worker erstellen (enthält das Controller-Zertifikat)
    keytool -exportcert \
        -alias scancentral \
        -keystore "$KEYSTORE_FILE" \
        -storepass "$KEYSTORE_PASSWORD" \
        -file "/tmp/scancentral-cert.pem" \
        -rfc 2>/dev/null

    TRUSTSTORE_PASSWORD=$(openssl rand -base64 24)
    echo -n "$TRUSTSTORE_PASSWORD" > "$TRUSTSTORE_PW_FILE"

    keytool -importcert \
        -alias scancentral \
        -file "/tmp/scancentral-cert.pem" \
        -keystore "$TRUSTSTORE_FILE" \
        -storepass "$TRUSTSTORE_PASSWORD" \
        -noprompt 2>/dev/null

    rm -f /tmp/scancentral-cert.pem
    echo "  ✓ Truststore erstellt: $TRUSTSTORE_FILE"
else
    echo "  → Keystore existiert bereits, überspringe"
fi
echo ""

# --- 6. Verzeichnisse erstellen ---------------------------------------------
echo -e "${BOLD}[6/8] Verzeichnisse erstellen...${NC}"
mkdir -p volumes/data
mkdir -p volumes/secrets

# Auf Linux: Berechtigungen für Container-User (UID 1111) setzen
if [[ "$(uname)" == "Linux" ]]; then
    echo "  → Linux erkannt, setze Berechtigungen (UID 1111)..."
    sudo chown -R 1111:1111 volumes/data volumes/secrets
    sudo chmod -R 770 volumes/data volumes/secrets
fi
echo "  ✓ Verzeichnisse bereit"
echo ""

# --- 7. Docker-Images prüfen ------------------------------------------------
echo -e "${BOLD}[7/8] Docker-Images prüfen...${NC}"
echo "  Versuche Images zu pullen (Docker Hub Login für 'fortifydocker' erforderlich)..."
if $COMPOSE_CMD pull 2>/dev/null; then
    echo "  ✓ Images erfolgreich geladen"
else
    echo -e "${YELLOW}  ⚠ Images konnten nicht geladen werden.${NC}"
    echo "    Bitte stelle sicher, dass du bei Docker Hub eingeloggt bist:"
    echo "    docker login"
    echo "    (Dein Account muss Zugriff auf 'fortifydocker' haben)"
fi
echo ""

# --- 8. Docker-Netzwerk und Start -------------------------------------------
echo -e "${BOLD}[8/8] Starten...${NC}"

# Netzwerk erstellen, falls es nicht existiert
NETWORK_NAME=$(grep DOCKER_NETWORK_NAME .env 2>/dev/null | grep -v '^#' | cut -d= -f2 || echo "fortify")
NETWORK_NAME=${NETWORK_NAME:-fortify}
if ! docker network inspect "$NETWORK_NAME" &>/dev/null; then
    docker network create "$NETWORK_NAME"
    echo "  ✓ Docker-Netzwerk '$NETWORK_NAME' erstellt"
else
    echo "  → Docker-Netzwerk '$NETWORK_NAME' existiert bereits"
fi

read -p "  Container jetzt starten? (j/n) " START_NOW
if [[ "$START_NOW" =~ ^[jJyY]$ ]]; then
    $COMPOSE_CMD up -d
    echo ""
    echo -e "${GREEN}${BOLD}=== Setup abgeschlossen ===${NC}"
    echo ""
    echo "  ScanCentral SAST Controller: https://localhost:9443/scancentral-ctrl"
    echo ""
    echo -e "${YELLOW}  Nächste Schritte:${NC}"
    echo "  1. Öffne die SSC-Administration unter https://localhost:8443"
    echo "  2. Gehe zu Administration → Configuration → ScanCentral SAST"
    echo "  3. Aktiviere ScanCentral SAST und trage die Controller-URL ein:"
    echo "     https://sast-ctrl:8443/scancentral-ctrl"
    echo "  4. Trage das Auth-Token ein (siehe: volumes/secrets/scancentral-authtoken)"
    echo ""
    echo "  Logs anzeigen:    $COMPOSE_CMD logs -f"
    echo "  Container stoppen: $COMPOSE_CMD down"
else
    echo ""
    echo -e "${GREEN}${BOLD}=== Setup abgeschlossen ===${NC}"
    echo ""
    echo "  Starte die Container mit: $COMPOSE_CMD up -d"
    echo ""
    echo -e "${YELLOW}  Vergiss nicht, danach in der SSC-Administration${NC}"
    echo -e "${YELLOW}  ScanCentral SAST zu aktivieren und die Controller-URL einzutragen.${NC}"
fi
