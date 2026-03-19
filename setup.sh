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
AUTHTOKEN_FILE="volumes/secrets/scancentral-worker-auth-token"
if [ ! -f "$AUTHTOKEN_FILE" ]; then
    AUTH_TOKEN=$(openssl rand -hex 32)
    # Das gleiche Token wird für Worker, Client und SSC-Secret verwendet
    echo -n "$AUTH_TOKEN" > "volumes/secrets/scancentral-worker-auth-token"
    echo -n "$AUTH_TOKEN" > "volumes/secrets/scancentral-client-auth-token"
    echo -n "$AUTH_TOKEN" > "volumes/secrets/scancentral-ssc-scancentral-ctrl-secret"
    echo "  ✓ Auth-Token generiert"
    echo ""
    echo -e "${YELLOW}  ⚠ WICHTIG: Dieses Token muss auch in der SSC-Administration${NC}"
    echo -e "${YELLOW}    unter ScanCentral SAST eingetragen werden.${NC}"
    echo -e "${YELLOW}    Token: ${AUTH_TOKEN}${NC}"
else
    echo "  → Auth-Token existiert bereits, überspringe"
fi
echo ""

# --- 5. HTTPS-Zertifikat erstellen ------------------------------------------
echo -e "${BOLD}[5/8] HTTPS-Zertifikat für Controller erstellen...${NC}"
KEYSTORE_FILE="volumes/secrets/httpKeystore.jks"
KEYSTORE_PW_FILE="volumes/secrets/keystore_password"
TRUSTSTORE_FILE="volumes/secrets/truststore.jks"
TRUSTSTORE_PW_FILE="volumes/secrets/truststore_password"

if [ ! -f "$KEYSTORE_FILE" ]; then
    KEYSTORE_PASSWORD=$(openssl rand -base64 24)
    echo -n "$KEYSTORE_PASSWORD" > "$KEYSTORE_PW_FILE"

    # JKS Keystore für den Controller
    keytool -genkeypair \
        -alias scancentral \
        -keyalg RSA \
        -keysize 2048 \
        -validity 365 \
        -storetype JKS \
        -keystore "$KEYSTORE_FILE" \
        -storepass "$KEYSTORE_PASSWORD" \
        -keypass "$KEYSTORE_PASSWORD" \
        -dname "CN=sast-ctrl, OU=Fortify, O=OpenText, L=Munich, ST=Bavaria, C=DE" \
        -ext "SAN=DNS:sast-ctrl,DNS:localhost,IP:127.0.0.1" \
        2>/dev/null

    echo "  ✓ Keystore erstellt: $KEYSTORE_FILE"

    # Zertifikat exportieren und Truststore für Worker erstellen
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

# --- 6. SSL-Trust mit SSC konfigurieren --------------------------------------
echo -e "${BOLD}[6/10] SSL-Trust zwischen Controller und SSC konfigurieren...${NC}"

# SSC-Secrets-Verzeichnis finden
SSC_SECRETS=""
for candidate in "../fortify-ssc-docker-setup/ssc-webapp/secrets" "../../fortify-ssc-docker-setup/ssc-webapp/secrets"; do
    if [ -d "$candidate" ]; then
        SSC_SECRETS="$candidate"
        break
    fi
done

if [ -z "$SSC_SECRETS" ]; then
    echo ""
    read -p "  Pfad zum SSC-Secrets-Verzeichnis (z.B. ../fortify-ssc-docker-setup/ssc-webapp/secrets): " SSC_SECRETS
fi

if [ -d "$SSC_SECRETS" ]; then
    KEYSTORE_PASSWORD=$(cat "$KEYSTORE_PW_FILE")
    TRUSTSTORE_PASSWORD=$(cat "$TRUSTSTORE_PW_FILE")

    # A) Controller-Cert → SSC-Truststore (damit SSC dem Controller vertraut)
    keytool -exportcert -alias scancentral \
        -keystore "$KEYSTORE_FILE" \
        -storepass "$KEYSTORE_PASSWORD" \
        -file "/tmp/scancentral-ctrl-cert.pem" -rfc 2>/dev/null

    # SSC-Truststore erstellen oder erweitern (basiert auf System-cacerts)
    if [ ! -f "$SSC_SECRETS/truststore.jks" ]; then
        # Versuche cacerts aus dem SSC-Container zu kopieren
        if docker inspect ssc-webapp &>/dev/null; then
            docker exec ssc-webapp cat /etc/pki/java/cacerts > "$SSC_SECRETS/truststore.jks" 2>/dev/null || \
            keytool -genkeypair -alias dummy -keystore "$SSC_SECRETS/truststore.jks" -storepass changeit -keypass changeit -dname "CN=dummy" 2>/dev/null && \
            keytool -delete -alias dummy -keystore "$SSC_SECRETS/truststore.jks" -storepass changeit 2>/dev/null
        else
            keytool -genkeypair -alias dummy -keystore "$SSC_SECRETS/truststore.jks" -storepass changeit -keypass changeit -dname "CN=dummy" 2>/dev/null
            keytool -delete -alias dummy -keystore "$SSC_SECRETS/truststore.jks" -storepass changeit 2>/dev/null
        fi
    fi

    keytool -importcert -alias scancentral-ctrl \
        -file "/tmp/scancentral-ctrl-cert.pem" \
        -keystore "$SSC_SECRETS/truststore.jks" \
        -storepass changeit -noprompt 2>/dev/null && \
    echo "  ✓ Controller-Zertifikat in SSC-Truststore importiert"

    echo -n "changeit" > "$SSC_SECRETS/truststore_password"
    rm -f "/tmp/scancentral-ctrl-cert.pem"

    # B) SSC-Cert → Controller-Truststore (damit Controller dem SSC vertraut)
    SSC_KEYSTORE=$(ls "$SSC_SECRETS"/ssc-keystore.* 2>/dev/null | head -1)
    if [ -n "$SSC_KEYSTORE" ] && [ -f "$SSC_SECRETS/keystore_password" ]; then
        SSC_KS_PW=$(cat "$SSC_SECRETS/keystore_password")
        keytool -exportcert -alias ssc-server \
            -keystore "$SSC_KEYSTORE" \
            -storepass "$SSC_KS_PW" \
            -file "/tmp/ssc-cert.pem" -rfc 2>/dev/null

        keytool -importcert -alias ssc-webapp \
            -file "/tmp/ssc-cert.pem" \
            -keystore "$TRUSTSTORE_FILE" \
            -storepass "$TRUSTSTORE_PASSWORD" -noprompt 2>/dev/null && \
        echo "  ✓ SSC-Zertifikat in Controller-Truststore importiert"

        rm -f "/tmp/ssc-cert.pem"
    else
        echo -e "${YELLOW}  ⚠ SSC-Keystore nicht gefunden – überspringe SSC-Cert-Import${NC}"
        echo "    Falls der Controller SSC nicht erreichen kann, importiere das SSC-Zertifikat manuell."
    fi

    # SSC docker-compose.yml automatisch patchen (JVM_TRUSTSTORE Zeilen einfügen)
    SSC_COMPOSE="$(dirname "$SSC_SECRETS")/../docker-compose.yml"
    if [ -f "$SSC_COMPOSE" ]; then
        if ! grep -q "JVM_TRUSTSTORE_FILE" "$SSC_COMPOSE"; then
            # Zeilen nach COM_FORTIFY_SSC_SECRETKEY einfügen
            sed -i.bak '/COM_FORTIFY_SSC_SECRETKEY/a\
      JVM_TRUSTSTORE_FILE: /app/secrets/truststore.jks\
      JVM_TRUSTSTORE_PASSWORD_FILE: /app/secrets/truststore_password' "$SSC_COMPOSE"
            rm -f "$SSC_COMPOSE.bak"
            echo "  ✓ SSC docker-compose.yml aktualisiert (JVM Truststore hinzugefügt)"
            echo -e "${YELLOW}  ⚠ Bitte SSC neu starten: cd $(dirname "$SSC_COMPOSE") && docker compose up -d${NC}"
        else
            echo "  → SSC docker-compose.yml enthält bereits JVM Truststore Konfiguration"
        fi
    else
        echo -e "${YELLOW}  ⚠ SSC docker-compose.yml nicht gefunden – bitte manuell ergänzen:${NC}"
        echo "     JVM_TRUSTSTORE_FILE: /app/secrets/truststore.jks"
        echo "     JVM_TRUSTSTORE_PASSWORD_FILE: /app/secrets/truststore_password"
    fi
else
    echo -e "${YELLOW}  ⚠ SSC-Secrets-Verzeichnis nicht gefunden – SSL-Trust muss manuell konfiguriert werden.${NC}"
fi
echo ""

# --- 7. Verzeichnisse erstellen ---------------------------------------------
echo -e "${BOLD}[7/10] Verzeichnisse erstellen...${NC}"
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
echo -e "${BOLD}[8/10] Docker-Images prüfen...${NC}"
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

# --- 9. Docker-Netzwerk erkennen und konfigurieren --------------------------
echo -e "${BOLD}[9/10] Docker-Netzwerk konfigurieren...${NC}"

# Automatisch das SSC-Netzwerk erkennen
SSC_NETWORK=$(docker network ls --format "{{.Name}}" 2>/dev/null | grep -i "ssc.*fortify\|fortify.*ssc" | head -1)
if [ -z "$SSC_NETWORK" ]; then
    SSC_NETWORK=$(docker network ls --format "{{.Name}}" 2>/dev/null | grep -i "fortify" | grep -v "^fortify-demo$" | head -1)
fi

if [ -n "$SSC_NETWORK" ]; then
    echo "  → SSC-Netzwerk erkannt: $SSC_NETWORK"
    sed -i.bak "s/DOCKER_NETWORK_NAME=.*/DOCKER_NETWORK_NAME=$SSC_NETWORK/" .env
    rm -f .env.bak
    NETWORK_NAME="$SSC_NETWORK"
else
    NETWORK_NAME=$(grep DOCKER_NETWORK_NAME .env 2>/dev/null | grep -v '^#' | cut -d= -f2 || echo "fortify")
    NETWORK_NAME=${NETWORK_NAME:-fortify}
    if ! docker network inspect "$NETWORK_NAME" &>/dev/null; then
        docker network create "$NETWORK_NAME"
        echo "  ✓ Docker-Netzwerk '$NETWORK_NAME' erstellt"
    else
        echo "  → Docker-Netzwerk '$NETWORK_NAME' existiert bereits"
    fi
fi
echo "  ✓ Netzwerk: $NETWORK_NAME"

read -p "  Container jetzt starten? (j/n) " START_NOW
if [[ "$START_NOW" =~ ^[jJyY]$ ]]; then
    $COMPOSE_CMD up -d
    echo ""
    echo -e "${GREEN}${BOLD}=== Setup abgeschlossen ===${NC}"
    echo ""
    echo "  ScanCentral SAST Controller: https://localhost:9443/scancentral-ctrl"
    echo ""
    echo -e "${YELLOW}  Nächste Schritte:${NC}"
    echo ""
    echo "  1. SSC docker-compose.yml: Folgende Zeilen unter 'environment' ergänzen:"
    echo "       JVM_TRUSTSTORE_FILE: /app/secrets/truststore.jks"
    echo "       JVM_TRUSTSTORE_PASSWORD_FILE: /app/secrets/truststore_password"
    echo "     Dann SSC neu starten: docker compose up -d"
    echo ""
    echo "  2. SSC-Administration (https://localhost:8443):"
    echo "     → Administration → Configuration → ScanCentral SAST"
    echo "     → Enable ScanCentral SAST aktivieren"
    echo "     → ScanCentral Controller URL: https://sast-ctrl:8443/scancentral-ctrl"
    echo "     → SSC shared secret: $(cat volumes/secrets/scancentral-ssc-scancentral-ctrl-secret 2>/dev/null)"
    echo "     → Save klicken"
    echo ""
    echo "  3. SSC neu starten: docker compose restart ssc-webapp"
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
