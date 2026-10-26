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
SANDERS_DEBIAN_INCLUDE_GENERIC_QCOM_FIRMWARE=1 \
SANDERS_NTP_SERVERS='a.st1.ntp.br b.st1.ntp.br pool.ntp.org' \
bash sh/build.sh rootfs debian
```

O rootfs é somente Debian arm64. O kernel monta a partição `userdata` pelo
PARTUUID `c2f3b3c6-acb4-332f-fe55-920f956be79d`, sem depender do número
atribuído ao MMC. Para outro layout, use `SANDERS_BOOT_ROOT=PARTUUID=...`.

O firmware Qualcomm genérico permanece habilitado por segurança para Venus,
remoteproc e WCNSS. O modo `=0` é um debloat experimental e deve ser usado
somente se esses blocos não forem necessários no teste.

## GPU Adreno 506

O device tree já habilita o nó `qcom,adreno-506` e o kernel usa o driver
`DRM_MSM`. O build agora embute `a530_pm4.fw`, `a530_pfp.fw` e o ZAP shader
`a506_zap.*` no kernel, resolvendo a falha de firmware que acontecia antes do
mount da `userdata`. O userspace usa Mesa/Freedreno; a série A5xx não possui
suporte Turnip/Vulkan upstream.
