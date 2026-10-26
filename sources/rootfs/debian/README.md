# Rootfs Debian do Sanders

## Fluxo

1. `profile.sh` define os padrões do Debian 13 Trixie arm64.
2. `build.sh` cria o sistema mínimo com `mmdebstrap`.
3. O checkpoint do kernel e os módulos são incorporados.
4. O firmware Sanders é clonado do repositório Vanadium OSS e instalado.
5. O kernel embute o firmware inicial do Adreno 506, que é requisitado antes
   de a `userdata` ser montada.
6. O rootfs inclui o runtime Mesa/Freedreno para OpenGL e OpenGL ES.
7. O overlay instala USB/RNDIS, SSH, Wi-Fi, módulos e sincronização NTP.
8. O script remove payload não utilizado, identidades de build e helpers QEMU,
   valida o runtime e gera ext4/tarball.

## Personalização

Os padrões podem ser substituídos sem alterar os arquivos versionados:

```bash
SANDERS_DEBIAN_IMAGE_SIZE_MIB=1024 \
SANDERS_ROOT_PASSWORD=sanders \
SANDERS_LIGHT_PASSWORD=123 \
SANDERS_ADMIN_PUBKEY_FILE="$HOME/.ssh/id_ed25519.pub" \
SANDERS_DEBIAN_INCLUDE_GENERIC_QCOM_FIRMWARE=0 \
SANDERS_NTP_SERVERS='pool.ntp.org time.cloudflare.com time.google.com' \
bash sh/build.sh rootfs debian
```

O acesso SSH e somente por chave. O build cria light com a chave publica
fornecida, instala a mesma chave para o root, bloqueia a senha do root e
desativa PasswordAuthentication. A senha 123 de light existe apenas
para uso local/recovery e pode ser trocada por SANDERS_LIGHT_PASSWORD.

O rootfs é somente Debian arm64. O kernel monta a partição `userdata` pelo
PARTUUID `c2f3b3c6-acb4-332f-fe55-920f956be79d`, sem depender do número
atribuído ao MMC. Para outro layout, use `SANDERS_BOOT_ROOT=PARTUUID=...`.

O firmware Qualcomm genérico fica desabilitado por padrão para reduzir cerca
de 305 MiB de payload de outros SoCs. O kernel já embute o firmware A530 e o
checkout Sanders fornece WCNSS, ADSP e Venus. Use `=1` somente para investigar
um probe que peça explicitamente um firmware genérico.

O `alsa-utils` também não entra na imagem mínima; o áudio continua sendo uma
função do kernel, mas as ferramentas de teste podem ser instaladas depois com
`apt install alsa-utils`.

## GPU Adreno 506

O device tree já habilita o nó `qcom,adreno-506` e o kernel usa o driver
`DRM_MSM`. O build agora embute `a530_pm4.fw`, `a530_pfp.fw` e o ZAP shader
`a506_zap.*` no kernel, resolvendo a falha de firmware que acontecia antes do
mount da `userdata`. O userspace usa Mesa/Freedreno; a série A5xx não possui
suporte Turnip/Vulkan upstream.
