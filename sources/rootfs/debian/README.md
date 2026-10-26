# Rootfs Debian do Sanders

## Fluxo

1. `profile.sh` define os padrões do Debian Bookworm arm64.
2. `build.sh` cria o sistema mínimo com `mmdebstrap`.
3. O checkpoint do kernel e os módulos são incorporados.
4. O firmware Sanders é clonado do repositório Vanadium OSS e instalado.
5. O overlay instala USB/RNDIS, SSH, Wi-Fi, módulos e sincronização NTP.
6. O script remove payload não utilizado, valida symlinks e gera ext4/tarball.

## Personalização

Os padrões podem ser substituídos sem alterar os arquivos versionados:

```bash
SANDERS_DEBIAN_IMAGE_SIZE_MIB=1024 \
SANDERS_ROOT_PASSWORD=sanders \
SANDERS_NTP_SERVERS='a.st1.ntp.br b.st1.ntp.br pool.ntp.org' \
bash sh/build.sh rootfs debian
```

O rootfs é somente Debian arm64. A imagem espera o label `debian-root` e o
kernel Sanders monta a `userdata` do eMMC em `/dev/mmcblk0p54`.
