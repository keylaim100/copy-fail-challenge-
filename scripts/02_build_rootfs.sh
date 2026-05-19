#!/usr/bin/env bash
# scripts/02_build_rootfs.sh
# Construye el initramfs con BusyBox + Python 3.10 + SSH
# Los estudiantes necesitan Python 3.10+ para ejecutar el PoC (os.splice)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUSYBOX_SRC="$WORKSPACE_ROOT/kernel/busybox"
INITRAMFS_DIR="$WORKSPACE_ROOT/kernel/initramfs"
BUILD_DIR="$WORKSPACE_ROOT/kernel/build"
JOBS=$(nproc)

GREEN='\033[1;32m'
CYAN='\033[1;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${CYAN}[1/6] Clonando BusyBox...${NC}"
if [ ! -d "$BUSYBOX_SRC" ]; then
  git clone --depth 1 https://git.busybox.net/busybox "$BUSYBOX_SRC"
fi

cd "$BUSYBOX_SRC"
echo -e "${CYAN}[2/6] Configurando BusyBox (binario estático)...${NC}"
make defconfig
# Compilación estática para no necesitar librerías externas

sed -i 's/# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config
grep -q "CONFIG_STATIC=y" .config || echo "CONFIG_STATIC=y" >> .config
sed -i 's/CONFIG_TC=y/CONFIG_TC=n/' .config   

echo -e "${CYAN}[3/6] Compilando BusyBox...${NC}"
make -j"$JOBS" 2>&1 | tail -3

echo -e "${CYAN}[4/6] Instalando BusyBox en el initramfs...${NC}"
mkdir -p "$INITRAMFS_DIR"
make CONFIG_PREFIX="$INITRAMFS_DIR" install

# Configurar permisos SUID correctos para que su pueda elevar privilegios
chmod 4755 "$INITRAMFS_DIR/bin/busybox" 2>/dev/null || true
chmod 4755 "$INITRAMFS_DIR/bin/su" 2>/dev/null || true
chmod 4755 "$INITRAMFS_DIR/usr/bin/su" 2>/dev/null || true

# ── Estructura mínima del sistema de archivos ──────────────────────────────────
mkdir -p "$INITRAMFS_DIR"/{proc,sys,dev,tmp,etc,root,home/student,usr/bin,run}

# Python 3 del host → copiarlo al initramfs con sus dependencias
echo -e "${CYAN}[5/6] Incluyendo Python 3 en el initramfs...${NC}"
PYTHON_BIN=$(which python3)
cp "$PYTHON_BIN" "$INITRAMFS_DIR/usr/bin/python3"
# Copiar librerías necesarias para Python
for lib in $(ldd "$PYTHON_BIN" 2>/dev/null | grep -oE '/[^ ]+\.so[^ ]*'); do
  mkdir -p "$INITRAMFS_DIR$(dirname $lib)"
  cp -L "$lib" "$INITRAMFS_DIR$lib" 2>/dev/null || true
done
# Python stdlib mínima
echo -e "${CYAN}[INFO] Localizando librerías de Python en el host...${NC}"
HOST_PYTHON_LIB=$(python3 -c "import sysconfig; print(sysconfig.get_path('stdlib'))")
PYTHON_VER=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")

mkdir -p "$INITRAMFS_DIR/usr/lib/python${PYTHON_VER}"
if [ -d "$HOST_PYTHON_LIB" ]; then
    echo -e "${GREEN}Copiando librerías desde: $HOST_PYTHON_LIB${NC}"
    cp -r "$HOST_PYTHON_LIB"/* "$INITRAMFS_DIR/usr/lib/python${PYTHON_VER}/" 2>/dev/null || true
fi
ln -sf python3 "$INITRAMFS_DIR/usr/bin/python" 2>/dev/null || true

# ── Usuario student (sin privilegios, como en el reto real) ───────────────────
cat > "$INITRAMFS_DIR/etc/passwd" << 'EOF'
root:x:0:0:root:/root:/bin/sh
student:x:1001:1001:student:/home/student:/bin/sh
EOF

cat > "$INITRAMFS_DIR/etc/shadow" << 'EOF'
root::19000:0:99999:7:::
student:$6$salt$hashedpassword:19000:0:99999:7:::
EOF

cat > "$INITRAMFS_DIR/etc/group" << 'EOF'
root:x:0:
student:x:1001:student
EOF

# ── /etc/profile con PATH útil ─────────────────────────────────────────────────
cat > "$INITRAMFS_DIR/etc/profile" << 'EOF'
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PS1='[\u@copy-fail \w]\$ '
echo ""
echo "  Bienvenido al kernel vulnerable (CVE-2026-31431)"
echo "  Usuario: $(id)"
echo "  Kernel:  $(uname -r)"
echo "  Módulos cargados con algif:"
echo "  $(cat /proc/modules | grep alg || echo '  (ninguno detectado aún)')"
echo ""
EOF

# ── Script init ────────────────────────────────────────────────────────────────
cat > "$INITRAMFS_DIR/init" << 'INITEOF'
#!/bin/sh
mkdir -p /proc /sys /dev /tmp
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || mdev -s
mount -t tmpfs none /tmp

# Cargar módulos crypto necesarios para la vulnerabilidad
modprobe algif_aead 2>/dev/null || true
modprobe authencesn 2>/dev/null || true

# Hostname identificador (para validación anti-copia)
STUDENT_ID="${STUDENT_ID:-unknown}"
hostname "copy-fail-${STUDENT_ID}"

echo ""
echo "  ╔══════════════════════════════════════════╗"
echo "  ║   KERNEL VULNERABLE — CVE-2026-31431     ║"
echo "  ║   $(uname -r | cut -c1-42)               ║"
echo "  ╚══════════════════════════════════════════╝"
echo ""

# Iniciar SSH daemon si existe
if [ -x /usr/sbin/sshd ]; then
  /usr/sbin/sshd -D &
fi

# Login como student (sin privilegios)
exec su - student
INITEOF

# ── Copiar el exploit estático al home de student ───────────────────────────
echo -e "${CYAN}[EXTRA] Inyectando exploit_static con permisos SUID...${NC}"
cp "$WORKSPACE_ROOT/exploit_static" "$INITRAMFS_DIR/home/student/exploit_static"

# ESTA LÍNEA ES LA CLAVE: Cambia el dueño a root y le da el bit SUID (4755)
chown root:root "$INITRAMFS_DIR/home/student/exploit_static"
chmod 4755 "$INITRAMFS_DIR/home/student/exploit_static"

chmod +x "$INITRAMFS_DIR/init"

echo -e "${CYAN}[6/6] Empaquetando initramfs...${NC}"
cd "$INITRAMFS_DIR"
find . | cpio -o -H newc | gzip > "$BUILD_DIR/initramfs.cpio.gz"

echo ""
echo -e "${GREEN}✓ rootfs listo → kernel/build/initramfs.cpio.gz${NC}"
echo ""
echo -e "  Siguiente paso: ${CYAN}make qemu${NC}"
echo -e "  (o: ${CYAN}STUDENT_ID=tunombre make qemu${NC})"
