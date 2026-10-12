# Instalar Docker en Debian

Montar Docker en Debian a mano es siempre lo mismo: clave GPG, repo de apt, paquetes, usuario en el grupo `docker`, Compose… Este repositorio trae **un script con menú** que automatiza eso usando el **Docker Engine oficial** (docker.com, no el `docker.io` de Debian).

Probado por mí en **Debian 13 (trixie)**, amd64, en **WSL2** y en **bare metal** con systemd.

---

## Qué hace el script

Al ejecutar `./install-docker-debian.sh` ves un menú. Lo normal en una máquina nueva es **Instalación completa**. Eso, en orden y con confirmaciones tuyas:

1. Instala dependencias de apt si faltan (`ca-certificates`, `curl`, `gnupg`).
2. Opcionalmente quita paquetes viejos que chocan (`docker.io`, etc.).
3. Añade el repositorio oficial de Docker para tu versión de Debian (lee `VERSION_CODENAME` del sistema).
4. Instala `docker-ce`, CLI, `containerd`, Buildx y el plugin de Compose.
5. Te pregunta **cómo quieres que arranque el daemon** (bajo demanda, siempre activo o manual).
6. **Te añade al grupo `docker`** con `usermod` — no tienes que hacerlo a mano.
7. Opcional: prueba `hello-world`, helpers de desarrollo, etc.

El resto del menú sirve para reconfigurar sin reinstalar: quitar conflictos, helpers, diagnóstico, arrancar/parar Docker o cambiar de perfil.

Si algo falla, el script escribe un log **`install-docker-debian.log`** en la carpeta donde está el `.sh` (solo en tu máquina; no hace falta subirlo a Git).

---

## Cómo lo ejecuto

```bash
git clone https://github.com/jcdelaguila87/instalar-docker-en-debian.git
cd instalar-docker-en-debian
chmod +x install-docker-debian.sh
./install-docker-debian.sh
```

### Después de la instalación

El script ya te mete en el grupo `docker`. Linux no refresca los grupos en la terminal que tienes abierta **en caliente**, así que:

**Cierra esa terminal y abre otra** (en WSL: cierra la pestaña o la sesión y entra de nuevo).

Luego prueba:

```bash
docker compose version
docker ps
```

Si aún pide `sudo`, casi seguro sigues en la sesión vieja — vuelve a cerrar y abrir.

---

## Requisitos

- Debian con soporte en el [repo de Docker](https://docs.docker.com/engine/install/debian/) (12, 13…).
- `sudo` e internet.
- **systemd** activo. En WSL: `[boot]` → `systemd=true` en `/etc/wsl.conf` y `wsl --shutdown` en Windows.

---

## Cómo arranca Docker (lo eliges tú)

Yo en el portátil uso casi siempre **bajo demanda**: el daemon no está todo el día en RAM; se levanta cuando hago un `docker …`. El primer comando puede tardar unos segundos. A veces, al terminar, lo paro con el menú **Arrancar / parar / cambiar perfil** o con `sudo systemctl stop docker.service`.

En la instalación (o en ese mismo menú más tarde) puedes elegir:

| Opción | En pocas palabras |
|--------|-------------------|
| **Bajo demanda** | Arranca cuando lo necesitas (mi opción habitual). |
| **Siempre activo** | El daemon queda como servicio al boot (servidor o uso intenso). |
| **Manual** | Tú lo inicias cuando quieras; cero autoarranque. |

---

## Helpers de desarrollo (opcionales)

Si en la instalación (o en el menú) aceptas helpers, el script **crea cosas en la carpeta del clone** (`bin/`, una plantilla compose, etc.) para usar Node/Python/PHP en contenedores sin instalarlos en Debian. Si no te interesa, responde que no y te quedas solo con Docker.

---

## Qué instala

Paquetes del repo oficial: Engine, CLI, `containerd`, Buildx y Compose plugin. No instala Docker Desktop.

---

## WSL y bare metal

Misma instalación. En WSL el script solo avisa si systemd no está bien. Lo del grupo `docker` y **cerrar sesión** aplica igual en ambos.

---

Repo mínimo: `install-docker-debian.sh` + este README. Clonas, ejecutas, cierras terminal, listo.
