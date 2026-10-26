Receitas Debian do builder Sanders.

`rootfs/debian/build.sh` monta um Debian bookworm arm64 minimo e incorpora o
checkpoint validado do kernel mainline. O kernel e o firmware sao clonados
automaticamente para `cache/` durante o build.
