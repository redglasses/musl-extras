# Copyright 1999-2018 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

EAPI=6

LLVM_MAX_SLOT=7
PYTHON_COMPAT=( python{2_7,3_{5,6,7}} )

inherit check-reqs eapi7-ver llvm multiprocessing multilib-build python-any-r1 rust-toolchain toolchain-funcs

if [[ ${PV} = *beta* ]]; then
	betaver=${PV//*beta}
	BETA_SNAPSHOT="${betaver:0:4}-${betaver:4:2}-${betaver:6:2}"
	MY_P="rustc-beta"
	SLOT="beta/${PV}"
	SRC="${BETA_SNAPSHOT}/rustc-beta-src.tar.xz"
else
	ABI_VER="$(ver_cut 1-2)"
	SLOT="stable/${ABI_VER}"
	MY_P="rustc-${PV}"
	SRC="${MY_P}-src.tar.xz"
	KEYWORDS="~amd64 ~arm64 ~x86"
fi

RUST_STAGE0_VERSION="1.$(($(ver_cut 2) - 1)).1"

DESCRIPTION="Systems programming language from Mozilla"
HOMEPAGE="https://www.rust-lang.org/"

SRC_URI="https://static.rust-lang.org/dist/${SRC} -> rustc-${PV}-src.tar.xz"
		# $(rust_all_arch_uris rust-${RUST_STAGE0_VERSION})"

ALL_LLVM_TARGETS=( AArch64 AMDGPU ARM BPF Hexagon Lanai Mips MSP430
	NVPTX PowerPC Sparc SystemZ X86 XCore )
ALL_LLVM_TARGETS=( "${ALL_LLVM_TARGETS[@]/#/llvm_targets_}" )
LLVM_TARGET_USEDEPS=${ALL_LLVM_TARGETS[@]/%/?}

LICENSE="|| ( MIT Apache-2.0 ) BSD-1 BSD-2 BSD-4 UoI-NCSA"

IUSE="clippy cpu_flags_x86_sse2 debug doc jemalloc libressl rls rustfmt system-llvm system-rust wasm ${ALL_LLVM_TARGETS[*]}"

COMMON_DEPEND=">=app-eselect/eselect-rust-0.3_pre20150425
		jemalloc? ( dev-libs/jemalloc )
		sys-libs/zlib
		!libressl? ( dev-libs/openssl:0= )
		libressl? ( dev-libs/libressl:0= )
		net-libs/libssh2
		net-libs/http-parser:=
		net-misc/curl[ssl]
		system-llvm? ( >=sys-devel/llvm-6:=[${LLVM_TARGET_USEDEPS// /,}] )"
DEPEND="${COMMON_DEPEND}
	${PYTHON_DEPS}
	|| (
		>=sys-devel/gcc-4.7
		>=sys-devel/clang-3.5
	)
	dev-util/cmake"
RDEPEND="${COMMON_DEPEND}
	!dev-util/cargo
	rustfmt? ( !dev-util/rustfmt )"
REQUIRED_USE="|| ( ${ALL_LLVM_TARGETS[*]} )
				x86? ( cpu_flags_x86_sse2 )"

S="${WORKDIR}/${MY_P}-src"

PATCHES=( "${FILESDIR}"/${PN}-1.31.0-clippy-sysroot.patch 
          "${FILESDIR}"/${PN}-1.29.1-Require-static-native-libraries-when-linking-static.patch
          "${FILESDIR}"/${PN}-1.32.0-Remove-nostdlib-and-musl_root.patch
          "${FILESDIR}"/${PN}-1.32.0-Switch-musl-targets-to-link-dynamically-by-default.patch
          "${FILESDIR}"/${PN}-1.27.1-Prefer-libgcc_eh-over-libunwind-for-musl.patch
          "${FILESDIR}"/${PN}-1.32.0-Fix-LLVM-build.patch
          "${FILESDIR}"/${PN}-1.28.0-Don-t-pass-CFLAGS-to-the-C-compiler.patch
          "${FILESDIR}"/${PN}-1.25.0-liblibc.patch
          "${FILESDIR}"/${PN}-1.25.0-Avoid_LLVM_name_conflicts.patch
          "${FILESDIR}"/${PN}-1.30.0-Fix-codegen-llvm-link-typo.patch
		  "${FILESDIR}"/${PN}-1.32.0-llvm-secureplt.patch
)

toml_usex() {
	usex "$1" true false
}

pkg_pretend() {
	# Ensure we have enough disk space to compile
	CHECKREQS_DISK_BUILD="6G"
	check-reqs_pkg_setup
}

pkg_setup() {
	python-any-r1_pkg_setup
	if use system-llvm; then
		llvm_pkg_setup
		local llvm_config="$(get_llvm_prefix "$LLVM_MAX_SLOT")/bin/llvm-config"

		export LLVM_LINK_SHARED=1
		export RUSTFLAGS="$RUSTFLAGS -Lnative=$("$llvm_config" --libdir)"
	fi
}

src_prepare() {
	if ! use system-rust; then
		local rust_stage0_root="${WORKDIR}"/rust-stage0

		local rust_stage0="rust-${RUST_STAGE0_VERSION}-$(rust_abi)"

		"${WORKDIR}/${rust_stage0}"/install.sh --disable-ldconfig --destdir="${rust_stage0_root}" --prefix=/ || die
	fi

	default
}

src_configure() {
	local rust_target="" rust_targets="" arch_cflags

	# Collect rust target names to compile standard libs for all ABIs.
	if use elibc_musl; then
		rust_targets="\"x86_64-unknown-linux-musl\""
	else
		for v in $(multilib_get_enabled_abi_pairs); do
			rust_targets="${rust_targets},\"$(rust_abi $(get_abi_CHOST ${v##*.}))\""
		done
	fi
	if use wasm; then
		rust_targets="${rust_targets},\"wasm32-unknown-unknown\""
	fi
	rust_targets="${rust_targets#,}"

	local extended="true" tools="\"cargo\","
	if use clippy; then
		tools="\"clippy\",$tools"
	fi
	if use rls; then
		tools="\"rls\",\"analysis\",\"src\",$tools"
	fi
	if use rustfmt; then
		tools="\"rustfmt\",$tools"
	fi

	if use system-rust; then
		local rust_stage0_root="/usr"
	else
		local rust_stage0_root="${WORKDIR}"/rust-stage0
	fi

	if use elibc_musl; then
		rust_target="x86_64-unknown-linux-musl"
	else
		rust_target="$(rust_abi)"
	fi

	cat <<- EOF > "${S}"/config.toml
		[llvm]
		ninja = true
		optimize = $(toml_usex !debug)
		release-debuginfo = $(toml_usex debug)
		assertions = $(toml_usex debug)
		targets = "${LLVM_TARGETS// /;}"
		link-shared = $(toml_usex system-llvm)
		[build]
		build = "${rust_target}"
		host = ["${rust_target}"]
		target = [${rust_targets}]
		cargo = "${rust_stage0_root}/bin/cargo"
		rustc = "${rust_stage0_root}/bin/rustc"
		docs = $(toml_usex doc)
		compiler-docs = $(toml_usex doc)
		submodules = false
		python = "${EPYTHON}"
		locked-deps = true
		vendor = true
		extended = ${extended}
		tools = [${tools}]
		[install]
		prefix = "${EPREFIX}/usr"
		libdir = "$(get_libdir)"
		docdir = "share/doc/${P}"
		mandir = "share/${P}/man"
		[rust]
		optimize = $(toml_usex !debug)
		debuginfo = $(toml_usex debug)
		debug-assertions = $(toml_usex debug)
		jemalloc = $(toml_usex jemalloc)
		default-linker = "$(tc-getCC)"
		channel = "stable"
		rpath = false
		lld = $(toml_usex wasm)
		optimize-tests = $(toml_usex !debug)
		codegen-tests = true
		dist-src = $(toml_usex debug)
	EOF

	if use elibc_musl; then
		arch_cflags="$(get_abi_CFLAGS ${v##*.})"

		cat <<- EOF >> "${S}"/config.env
			CFLAGS_${rust_target}=${arch_cflags}
		EOF

		cat <<- EOF >> "${S}"/config.toml
			[target.${rust_target}]
			cc = "$(tc-getBUILD_CC)"
			cxx = "$(tc-getBUILD_CXX)"
			linker = "$(tc-getCC)"
			ar = "$(tc-getAR)"
		EOF
		if use system-llvm; then
			cat <<- EOF >> "${S}"/config.toml
				llvm-config = "$(get_llvm_prefix)/bin/llvm-config"
			EOF
		fi
	else
		for v in $(multilib_get_enabled_abi_pairs); do
			rust_target=$(rust_abi $(get_abi_CHOST ${v##*.}))
			arch_cflags="$(get_abi_CFLAGS ${v##*.})"

			cat <<- EOF >> "${S}"/config.env
				CFLAGS_${rust_target}=${arch_cflags}
			EOF

			cat <<- EOF >> "${S}"/config.toml
				[target.${rust_target}]
				cc = "$(tc-getBUILD_CC)"
				cxx = "$(tc-getBUILD_CXX)"
				linker = "$(tc-getCC)"
				ar = "$(tc-getAR)"
			EOF
			if use system-llvm; then
				cat <<- EOF >> "${S}"/config.toml
					llvm-config = "$(get_llvm_prefix)/bin/llvm-config"
				EOF
			fi
		done
	fi

	if use wasm; then
		cat <<- EOF >> "${S}"/config.toml
			[target.wasm32-unknown-unknown]
			linker = "rust-lld"
		EOF
	fi
}

src_compile() {
	env $(cat "${S}"/config.env)\
		"${EPYTHON}" ./x.py build --config="${S}"/config.toml -j$(makeopts_jobs) \
		--exclude src/tools/miri || die # https://github.com/rust-lang/rust/issues/52305
}

src_install() {
	local rust_target abi_libdir

	env DESTDIR="${D}" "${EPYTHON}" ./x.py install || die

	mv "${D}/usr/bin/rustc" "${D}/usr/bin/rustc-${PV}" || die
	mv "${D}/usr/bin/rustdoc" "${D}/usr/bin/rustdoc-${PV}" || die
	mv "${D}/usr/bin/rust-gdb" "${D}/usr/bin/rust-gdb-${PV}" || die
	mv "${D}/usr/bin/rust-lldb" "${D}/usr/bin/rust-lldb-${PV}" || die
	mv "${D}/usr/bin/cargo" "${D}/usr/bin/cargo-${PV}" || die

	rm "${D}/usr/lib/rustlib/components" || die
	rm "${D}/usr/lib/rustlib/install.log" || die
	rm "${D}/usr/lib/rustlib"/manifest-* || die
	rm "${D}/usr/lib/rustlib/rust-installer-version" || die
	rm "${D}/usr/lib/rustlib/uninstall.sh" || die

	if use clippy; then
		mv "${D}/usr/bin/cargo-clippy" "${D}/usr/bin/cargo-clippy-${PV}" || die
		mv "${D}/usr/bin/clippy-driver" "${D}/usr/bin/clippy-driver-${PV}" || die
	fi
	if use rls; then
		mv "${D}/usr/bin/rls" "${D}/usr/bin/rls-${PV}" || die
	fi
	if use rustfmt; then
		mv "${D}/usr/bin/cargo-fmt" "${D}/usr/bin/cargo-fmt-${PV}" || die
		mv "${D}/usr/bin/rustfmt" "${D}/usr/bin/rustfmt-${PV}" || die
	fi

	if ! use elibc_musl; then
		# Copy shared library versions of standard libraries for all targets
		# into the system's abi-dependent lib directories because the rust
		# installer only does so for the native ABI.
		for v in $(multilib_get_enabled_abi_pairs); do
			if [ ${v##*.} = ${DEFAULT_ABI} ]; then
				continue
			fi
			abi_libdir=$(get_abi_LIBDIR ${v##*.})
			rust_target=$(rust_abi $(get_abi_CHOST ${v##*.}))
			mkdir -p "${D}/usr/${abi_libdir}"
			cp "${D}/usr/$(get_libdir)/rustlib/${rust_target}/lib"/*.so \
			   "${D}/usr/${abi_libdir}" || die
		done
	fi

	dodoc COPYRIGHT
	rm "${D}/usr/share/doc/${P}"/*.old || die
	rm "${D}/usr/share/doc/${P}/LICENSE-APACHE" || die
	rm "${D}/usr/share/doc/${P}/LICENSE-MIT" || die

	docompress "/usr/share/${P}/man"

	# FIXME:
	# Really not sure if that env is needed
	cat <<-EOF > "${T}"/50${P}
		MANPATH="/usr/share/${P}/man"
	EOF
	doenvd "${T}"/50${P}

	cat <<-EOF > "${T}/provider-${P}"
		/usr/bin/cargo
		/usr/bin/rustdoc
		/usr/bin/rust-gdb
		/usr/bin/rust-lldb
	EOF
	echo /usr/bin/cargo >> "${T}/provider-${P}"
	if use clippy; then
		echo /usr/bin/clippy-driver >> "${T}/provider-${P}"
		echo /usr/bin/cargo-clippy >> "${T}/provider-${P}"
	fi
	if use rls; then
		echo /usr/bin/rls >> "${T}/provider-${P}"
	fi
	if use rustfmt; then
		echo /usr/bin/rustfmt >> "${T}/provider-${P}"
		echo /usr/bin/cargo-fmt >> "${T}/provider-${P}"
	fi
	dodir /etc/env.d/rust
	insinto /etc/env.d/rust
	doins "${T}/provider-${P}"
}

pkg_postinst() {
	eselect rust update --if-unset

	elog "Rust installs a helper script for calling GDB and LLDB,"
	elog "for your convenience it is installed under /usr/bin/rust-{gdb,lldb}-${PV}."

	ewarn "cargo is now installed from dev-lang/rust{,-bin} instead of dev-util/cargo."
	ewarn "This might have resulted in a dangling symlink for /usr/bin/cargo on some"
	ewarn "systems. This can be resolved by calling 'sudo eselect rust set ${P}'."

	if has_version app-editors/emacs || has_version app-editors/emacs-vcs; then
		elog "install app-emacs/rust-mode to get emacs support for rust."
	fi

	if has_version app-editors/gvim || has_version app-editors/vim; then
		elog "install app-vim/rust-vim to get vim support for rust."
	fi

	if has_version 'app-shells/zsh'; then
		elog "install app-shells/rust-zshcomp to get zsh completion for rust."
	fi
}

pkg_postrm() {
	eselect rust unset --if-invalid
}
