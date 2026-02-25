.PHONY: setup cnode tgcalls-smoke tgcalls-plugin tgcalls-runtime-smoke install nif

ERTS_INCLUDE := $(shell erl -noshell -eval 'io:format("~s/erts-~s/include", [code:root_dir(), erlang:system_info(version)])' -s init stop)

setup: cnode nif install
	mix deps.get
	mix compile

cnode:
	bin/build_tdlib_cnode

tgcalls-smoke:
	bin/build_tgcalls_smoke

tgcalls-plugin:
	bin/build_tgcalls_register_plugin

tgcalls-runtime-smoke: tgcalls-plugin
	mix froth.tgcalls.smoke

nif: priv/speex_resample_nif.so

priv/speex_resample_nif.so: c_src/speex_resample_nif.c
	gcc -shared -fPIC -o $@ $< -I$(ERTS_INCLUDE) -lspeexdsp -O2

install:
	mkdir -p $(HOME)/.config/systemd/user
	ln -sf /srv/froth/froth.service $(HOME)/.config/systemd/user/froth.service
	systemctl --user daemon-reload
	systemctl --user enable --now froth
