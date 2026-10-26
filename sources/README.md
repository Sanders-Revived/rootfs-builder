Receitas Debian do builder Sanders.

O gerador Debian fica dividido em três partes:

- `rootfs/debian/profile.sh`: política da imagem, pacotes, tamanho, senha e NTP;
- `rootfs/debian/overlay/`: arquivos estáticos de runtime, USB/RNDIS, SSH e módulos;
- `rootfs/debian/build.sh`: montagem do Debian, kernel, firmware, validações e imagem ext4.

O build do kernel prepara em `cache/mainline/gpu-firmware/` os blobs do
Adreno 506: PM4/PFP do linux-firmware e ZAP do repositório Sanders. Eles são
embutidos no kernel porque o driver DRM é inicializado antes da montagem do
rootfs.

O kernel e o firmware são clonados automaticamente para `cache/` durante o
build. A receita aceita variáveis `SANDERS_*` para sobrescrever o perfil sem
editar o fluxo de montagem.
