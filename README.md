# Sanders mainline builder

Builder reproduzivel e enxuto para o Motorola Moto G5S Plus (Sanders). O
kernel e o firmware sao clonados automaticamente para caches ignorados pelo
Git; o repositorio guarda somente o codigo do builder e a receita Debian.

## Build do kernel

```sh
cd /home/light/rootfs-builder
bash sh/build.sh kernel
```

Por padrao, o script usa:

```text
repository: https://github.com/Sanders-Revived/linux.git
ref: barni2000/7.3/develop
cache: cache/sources/linux
firmware: https://gitlab.com/vanadium-oss/motorola-msm8953/mainline/sanders-firmware
```

O build clona ou atualiza o cache automaticamente. A configuracao e gerada
com `defconfig`, `no-unused-drivers.config`, `msm8953.config` e
`motorola-sanders.config`. O fragmento de limpeza desliga plataformas e
drivers fora do Sanders.

Opcoes:

```sh
bash sh/build.sh kernel --reuse  # valida o ultimo checkpoint
bash sh/build.sh kernel --clean  # recompila do zero o output do kernel
bash sh/build.sh update           # atualiza o cache clonado
bash sh/build.sh status
bash sh/build.sh all              # kernel + Debian rootfs
```

O build publica em `build/mainline/releases/` uma única imagem universal:

- `Image.gz`, `sanders.dtb` e `dt.img` (QCDT v2 para o lk2nd);
- `boot.img` Android legado com seleção automática de painel pelo lk2nd;
- `lk2nd.img`, configuração, `System.map`, `vmlinux`, módulos `.tar.zst` e
  `SHA256SUMS`.

O lk2nd lê o parâmetro `mdss_mdp.panel` herdado do bootloader stock e troca a
compatibilidade do nó de painel no DTB antes de entregar o kernel. Assim a
mesma imagem suporta Tianma NT35596 e DJN ILI7807D; os dois drivers permanecem
no kernel porque são necessários para essa seleção automática.

`boot.img` usa o formato Android legado que este lk2nd espera: página 2048,
base `0x80000000`, offset do kernel `0x8000`, tags `0x100`, `Image.gz` puro e
uma tabela Qualcomm QCDT v2 no campo DT da imagem. Os IDs QCDT identificam a
placa; o painel é identificado separadamente pelo parâmetro `mdss_mdp.panel`.

As imagens nao usam ramdisk: no Sanders, `system` e `mmcblk0p53` e
`userdata` e `mmcblk0p54`. O eMMC aparece como `mmcblk0` neste kernel; o SD
removivel aparece como `mmcblk1`, portanto o boot usa `/dev/mmcblk0p54` como
root da imagem Debian.
O caminho DRM/MSM, os helpers KMS, o backlight e os dois drivers de painel
Sanders sao built-in no kernel; assim o display nao depende de carregar modulo
depois que o Debian monta o rootfs.

O builder gera o cabecalho Android/QCDT localmente em
`sh/mainline/make-bootimg-qcdt.py`, seguindo o formato usado pelo mkbootimg do
lk2nd; assim ele nao depende da variante de `mkbootimg` instalada no host.

## Debian arm64

O fluxo Debian depende do checkpoint do kernel e gera uma receita mínima com
`mmdebstrap`, incluindo `Image.gz`, o DTB Sanders universal, `System.map`,
config e módulos em `/boot` e `/lib/modules`. Os formatos gerados são:

- tarball `tar.zst` para extracao;
- imagem ext4 de 1024 MiB, com no minimo 64 MiB livres.

```sh
bash sh/build.sh kernel
bash sh/build.sh rootfs debian
# ou, em uma etapa:
bash sh/build.sh all
```

No WSL, a receita usa `fakechroot` + `qemu-aarch64-static`; nao depende de
binfmt ARM64 funcional dentro do chroot. O host precisa ter `mmdebstrap`,
`fakechroot`, `fakeroot`, `qemu-user-static`, `zstd`, `rsync` e as bibliotecas
ARM64 de fakechroot/fakeroot. O builder nao instala essas dependencias sozinho.

As variaveis `SANDERS_DEBIAN_SUITE`, `SANDERS_DEBIAN_MIRROR`,
`SANDERS_DEBIAN_PACKAGES`, `SANDERS_DEBIAN_IMAGE_SIZE_MIB` e
`SANDERS_DEBIAN_MIN_FREE_MIB` permitem ajustar a receita.

## Rootfs Debian

O projeto suporta somente Debian arm64. A receita em
`sources/rootfs/debian/build.sh` clona o firmware mantido pelo Vanadium OSS,
registra o commit usado no `build-info.txt` e instala o modem, WCNSS e os
arquivos de calibracao WLAN do Sanders.

```sh
bash sh/build.sh rootfs
bash sh/build.sh rootfs debian
```

O kernel e seus modulos sao expostos a receita por variaveis como
`KERNEL_RELEASE`, `KERNEL_MODULES_ARCHIVE`, `KERNEL_CONFIG_FILE` e
`KERNEL_SYSTEM_MAP_FILE`. O firmware e exposto por
`FIRMWARE_SOURCE_DIR`, `FIRMWARE_REF` e `FIRMWARE_SHA`.
O rootfs usa a senha inicial `sanders` para o usuario `root`; ela pode ser
alterada no build com `SANDERS_ROOT_PASSWORD`.

O fragmento Sanders do kernel evita drivers que nao correspondem ao hardware
ou ao transporte escolhido: `ath10k`, RMI4 e funcoes USB ACM/serial ficam fora;
o Wi-Fi usa `wcn36xx`/WCNSS e o USB usa somente RNDIS.

## Instalacao no aparelho

A imagem Debian ext4 precisa ser gravada em `userdata` e a `boot.img` precisa
ser carregada pelo `lk2nd`. Isso apaga o Android e os dados do usuario; faca
backup antes:

```sh
fastboot flash boot lk2nd.img
# reinicie no lk2nd/fastboot e execute novamente:
fastboot flash userdata debian-trixie-arm64-sanders-7.3.0-<release>.ext4
fastboot flash boot boot.img       # Tianma/DJN selecionado pelo lk2nd
fastboot reboot
```

Para testar sem gravar a partição boot, use `fastboot boot boot.img` quando o
lk2nd já estiver ativo. O lk2nd reserva 512 KiB no início da partição boot;
por isso o arquivo `boot.img` publicado e a imagem Android pura, sem padding.

## Organizacao

```text
sh/build.sh                  entrada principal
sh/lib/common.sh             configuracao e validacoes compartilhadas
sh/mainline/build.sh         build do kernel
sh/mainline/update-source.sh atualizacao explicita da fonte
sh/rootfs/build.sh           gerador exclusivo do Debian
sources/rootfs/debian/       receita Debian arm64
build/mainline/              outputs do kernel
build/rootfs/debian/         releases Debian tar.zst/ext4
cache/mainline/              kernel clonado, checkpoint, modulos e ccache
cache/rootfs/                area de trabalho descartavel do Debian
cache/sources/               caches clonados do kernel e firmware
sources/                     somente receita e documentacao do builder
```

O builder nao executa GitHub Actions, nao instala pacotes do host
automaticamente e falha cedo quando uma dependencia ou fonte obrigatoria nao
existe.

## Por que estas mudancas existem

- `qcom_wcnss_pil` e `wcn36xx` sao carregados junto com o rootfs, e o firmware
  WCNSS/NV do Sanders e incluido no local esperado pelo kernel. Isso evita que
  o Wi-Fi dependa de uma inicializacao manual depois do boot.
- O gadget USB e RNDIS-only, como no rootfs doador, com endereco fixo
  `172.16.42.1/24` para o SSH. Ele tambem publica os descritores Microsoft e a
  classe USB composta `EF/04/01`, necessarios para o driver RNDIS nativo do
  Windows ser associado automaticamente.
- O QCDT inclui a tupla de hardware que o lk2nd le no Sanders
  (`platform=0x125`, `hw=0x8`). Sem ela o lk2nd retorna `dtb not found`, mesmo
  quando a imagem do kernel esta correta.
