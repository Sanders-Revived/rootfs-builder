# Sanders mainline builder

Builder local e enxuto para o Motorola Moto G5S Plus (Sanders). O kernel nao
e clonado automaticamente: o build usa o checkout local do nosso kernel.

## Build do kernel

```sh
cd /home/light/sanders-mainline
bash sh/build.sh kernel
```

Por padrao, o script usa:

```text
source: /home/light/linux-barni
branch: barni2000/7.3/develop
remote: https://github.com/Sanders-Revived/linux.git
```

Para usar outro checkout, defina `SANDERS_KERNEL_DIR`. A configuracao e
gerada com `defconfig`, `no-unused-drivers.config`, `msm8953.config` e
`motorola-sanders.config`. O fragmento de limpeza desliga plataformas e
drivers fora do Sanders.

Opcoes:

```sh
bash sh/build.sh kernel --reuse  # valida o ultimo checkpoint
bash sh/build.sh kernel --clean  # recompila do zero o output do kernel
bash sh/build.sh update           # fast-forward explicito da fonte
bash sh/build.sh status
bash sh/build.sh all              # kernel + Debian rootfs
```

O build publica em `build/mainline/releases/`:

- `Image.gz`, DTBs crus e tabelas QCDT v2 para o lk2nd;
- `boot.img` Android legado para o painel Tianma NT35596;
- `boot-djn.img` Android legado para o painel DJN ILI7807D;
- `msm8953-motorola-sanders.dtb` (Tianma);
- `msm8953-motorola-sanders-djn.dtb` (DJN);
- configuracao, `System.map`, `vmlinux`, modulos `.tar.zst` e `SHA256SUMS`.

`boot.img` usa o formato Android legado que este lk2nd espera: pagina 2048,
base `0x80000000`, offset do kernel `0x8000`, tags `0x100`, `Image.gz` puro e
uma tabela Qualcomm QCDT v2 no campo DT da imagem. O `boot-djn.img` usa a
mesma imagem de kernel com uma tabela QCDT contendo o DTB DJN. Isso evita
anexar um DTB cru ao gzip, que faz o lk2nd interpretar bytes do kernel como
versao da tabela.

As imagens nao usam ramdisk: o kernel monta a particao ext4 `userdata` pelo
dispositivo fixo `/dev/mmcblk0p53`. O label da imagem e `debian-root`, para
facilitar a identificacao e a validacao offline.
O caminho DRM/MSM, os helpers KMS, o backlight e os dois drivers de painel
Sanders sao built-in no kernel; assim o display nao depende de carregar modulo
depois que o Debian monta o rootfs.

O builder gera o cabecalho Android/QCDT localmente em
`sh/mainline/make-bootimg-qcdt.py`, seguindo o formato usado pelo mkbootimg do
lk2nd; assim ele nao depende da variante de `mkbootimg` instalada no host.

## Debian arm64

O fluxo Debian depende do checkpoint do kernel e gera uma receita minima com
`mmdebstrap`, incluindo `Image.gz`, os dois DTBs Sanders, `System.map`, config e
modulos em `/boot` e `/lib/modules`. Os formatos gerados sao:

- tarball `tar.zst` para extracao;
- imagem ext4 de 4096 MiB, com no minimo 64 MiB livres.

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

## Rootfs

Debian possui receita local em `sources/rootfs/debian/build.sh`. Alpine e
Ubuntu continuam como wrappers para receitas locais futuras; o repositorio
remoto antigo nao e clonado automaticamente.

```sh
bash sh/build.sh rootfs alpine
bash sh/build.sh rootfs debian
bash sh/build.sh rootfs ubuntu
```

O kernel e seus modulos sao expostos a receita por variaveis como
`KERNEL_RELEASE`, `KERNEL_MODULES_ARCHIVE`, `KERNEL_CONFIG_FILE` e
`KERNEL_SYSTEM_MAP_FILE`.

## Instalacao no aparelho

A imagem Debian ext4 precisa ser gravada em `userdata` e a `boot.img` precisa
ser carregada pelo `lk2nd`. Isso apaga o Android e os dados do usuario; faca
backup antes:

```sh
fastboot flash boot lk2nd.img
# reinicie no lk2nd/fastboot e execute novamente:
fastboot flash userdata debian-bookworm-arm64-sanders-7.3.0-<release>.ext4
fastboot flash boot boot.img       # Tianma NT35596
# ou: fastboot flash boot boot-djn.img  # DJN ILI7807D
fastboot reboot
```

Para testar sem gravar a particao boot, use `fastboot boot boot.img` ou
`fastboot boot boot-djn.img` quando o lk2nd ja estiver ativo. O lk2nd reserva 512 KiB no inicio da particao boot;
por isso o arquivo `boot.img` publicado e a imagem Android pura, sem padding.

## Organizacao

```text
sh/build.sh                  entrada principal
sh/lib/common.sh             configuracao e validacoes compartilhadas
sh/mainline/build.sh         build do kernel
sh/mainline/update-source.sh atualizacao explicita da fonte
sh/rootfs/build.sh           executor de receitas locais
sources/rootfs/debian/       receita Debian arm64
build/mainline/              outputs do kernel
build/rootfs/debian/         releases Debian tar.zst/ext4
cache/mainline/              checkpoint, modulos e ccache
cache/rootfs/                area de trabalho descartavel
sources/                     fontes externas opcionais
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
