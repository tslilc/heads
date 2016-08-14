modules 	:=
pwd 		:= $(shell pwd)
packages 	:= $(pwd)/packages
build		:= $(pwd)/build
config		:= $(pwd)/build

all: x230.rom



include modules/*

all: $(modules)

define prefix =
$(foreach _, $2, $1$_)
endef

define outputs =
$(foreach m,$1,$(call prefix,$(build)/$($m_dir)/,$($m_output)))
endef

#
# Generate the targets for a module.
#
# Special variables like $@ must be written as $$@ to avoid
# expansion during the first evaluation.
#
define define_module =
  # Fetch and verify the source tar file
  $(packages)/$($1_tar):
	wget -O "$$@" $($1_url)
  $(packages)/.$1_verify: $(packages)/$($1_tar)
	echo "$($1_hash) $$^" | sha256sum --check -
	touch "$$@"

  # Unpack the tar file and touch the canary so that we know
  # that the files are all present
  $(build)/$($1_dir)/.canary: $(packages)/.$1_verify
	tar -xf "$(packages)/$($1_tar)" -C "$(build)"
	if [ -r patches/$1-$($1_version).patch ]; then \
		( cd $(build)/$($1_dir) ; patch -p1 ) < patches/$1-$($1_version).patch; \
	fi
	touch "$$@"

  # Copy our stored config file into the unpacked directory
  $(build)/$($1_dir)/.config: config/$1.config $(build)/$($1_dir)/.canary
	cp "$$<" "$$@"

  # Use the module's configure variable to build itself
  $(build)/$($1_dir)/.configured: \
		$(build)/$($1_dir)/.canary \
		$(build)/$($1_dir)/.config
	cd "$(build)/$($1_dir)" ; $($1_configure)
	touch "$$@"

  # Build the target after any dependencies
  $(call outputs,$1): \
		$(build)/$($1_dir)/.configured \
		$(call outputs,$($1_depends))
	make -C "$(build)/$($1_dir)" $($1_target)

  # Short hand target for the module
  $1: $(call outputs,$1)

endef

$(foreach _, $(modules), $(eval $(call define_module,$_)))


#
# Files that should be copied into the initrd
# THis should probably be done in a more scalable manner
#
define initrd_bin =
initrd/bin/$(notdir $1): $1
	@if [ ! -d initrd/bin ]; then mkdir "initrd/bin"; fi
	cmp --quiet "$$@" "$$^" || \
	cp -a "$$^" "$$@"
initrd_bins += initrd/bin/$(notdir $1)
endef

$(foreach _, $(call outputs,kexec), $(eval $(call initrd_bin,$_)))
$(foreach _, $(call outputs,tpmtotp), $(eval $(call initrd_bin,$_)))
#$(eval $(call initrd_bin,$(build)/$(tpmtotp_dir)/unsealtotp))
#$(foreach _, $(call outputs,xen), $(eval $(call initrd_bin,$_)))

# hack to install busybox into the initrd
initrd_bins += initrd/bin/busybox

initrd/bin/busybox: $(build)/$(busybox_dir)/busybox
	cmp --quiet "$@" "$^" || \
	make \
		-C $(build)/$(busybox_dir) \
		CONFIG_PREFIX="$(pwd)/initrd" \
		install

# hack to build cbmem from coreboot
initrd_bins += initrd/bin/cbmem
initrd/bin/cbmem: $(build)/$(coreboot_dir)/util/cbmem/cbmem
	cmp --quiet "$^" "$@" \
	|| cp "$^" "$@"
$(build)/$(coreboot_dir)/util/cbmem/cbmem: $(build)/$(coreboot_dir)/.canary
	make -C "$(dir $@)"

# Mounting dm-verity file systems requires dm-verity to be installed
# We use gpgv to verify the signature on the root hash.
# Both of these should be brought in as modules instead of from /sbin
initrd_bins += initrd/bin/dmsetup
initrd/bin/dmsetup: /sbin/dmsetup
	cp "$<" "$@"
initrd_bins += initrd/bin/gpgv
initrd/bin/gpgv: /usr/bin/gpgv
	cp "$<" "$@"

# Update all of the libraries in the initrd based on the executables
# that were installed.
initrd_libs: $(initrd_bins)
	-find initrd/bin -type f -print0 \
		| xargs -0 strip
	./populate-lib \
		./initrd/lib/x86_64-linux-gnu/ \
		initrd/bin/* \
		initrd/sbin/* \



#
# initrd image creation
#
# The initrd is constructed from various bits and pieces
# Note the touch and sort operation on the find output -- this
# ensures that the files always have the same timestamp and
# appear in the same order.
#
# If there is in /dev/console, initrd can't startup.
# We have to force it to be included into the cpio image.
# Since we are picking up the system's /dev/console, the
# timestamp will not be reproducible.
#
#
initrd.cpio: $(initrd_bins) initrd_libs
	cd ./initrd ; \
	( \
		echo "/dev" ; \
		echo "/dev/console"; \
		find . \
	) \
	| cpio --quiet -H newc -o \
	| ../cpio-clean \
		> "../$@.tmp" 
	if ! cmp --quiet "$@" "$@.tmp"; then \
		mv "$@.tmp" "$@"; \
	else \
		echo "$@: Unchanged"; \
		rm "$@.tmp"; \
	fi
	

# populate the coreboot initrd image from the one we built.
# 4.4 doesn't allow this, but building from head does.
$(call outputs,linux): initrd.cpio
#$(call outputs,coreboot): $(build)/$(coreboot_dir)/initrd.cpio.xz
$(build)/$(coreboot_dir)/initrd.cpio.xz: initrd.cpio
	xz < "$<" > "$@"

# hack for the coreboot to find the linux kernel
$(build)/$(coreboot_dir)/bzImage: $(call outputs,linux)
	cmp --quiet "$@" "$^" || \
	cp -a "$^" "$@"
$(call outputs,coreboot): $(build)/$(coreboot_dir)/bzImage


# The CoreBoot gcc won't work for us since it doesn't have libc
#XGCC := $(build)/$(coreboot_dir)/util/crossgcc/xgcc/
#export CC := $(XGCC)/bin/x86_64-elf-gcc
#export LDFLAGS := -L/lib/x86_64-linux-gnu

x230.rom: $(build)/$(coreboot_dir)/build/coreboot.rom
	dd if="$<" of="$@" bs=1M skip=8

