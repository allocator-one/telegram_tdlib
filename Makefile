# Builds the td_json_client port shim that bridges a BEAM Port to TDLib.
#
# TDLib (libtdjson) is located via, in order:
#   1. the TDLIB_DIR environment variable, or
#   2. `brew --prefix tdlib` (macOS / Homebrew).
#
# When libtdjson cannot be found the native build is SKIPPED (not failed), so
# `mix compile` and the pure-Elixir test suite still work on machines without
# TDLib installed (e.g. CI). Install TDLib (`brew install tdlib`, or build from
# https://github.com/tdlib/td) and recompile to produce the shim.

PRIV_DIR = $(MIX_APP_PATH)/priv
SHIM = $(PRIV_DIR)/telegram_tdlib_shim

TDLIB_DIR ?= $(shell brew --prefix tdlib 2>/dev/null)
TDJSON := $(wildcard $(TDLIB_DIR)/lib/libtdjson*)

CXX ?= c++
# TDLIB_DIR is quoted in every recipe so a path with spaces (or shell
# metacharacters in a hostile build env) is treated as one literal argument.
CXXFLAGS += -std=c++14 -O2 -Wall -Wextra -I"$(TDLIB_DIR)/include"
LDFLAGS += -L"$(TDLIB_DIR)/lib" -ltdjson -Wl,-rpath,"$(TDLIB_DIR)/lib"

.PHONY: all clean

all:
ifeq ($(strip $(TDJSON)),)
	@echo "telegram_tdlib: libtdjson not found under '$(TDLIB_DIR)/lib'."
	@echo "telegram_tdlib: skipping native shim build. Install TDLib (e.g. \`brew install tdlib\`,"
	@echo "telegram_tdlib: or set TDLIB_DIR) and recompile to enable the Telegram client."
else
	@$(MAKE) $(SHIM)
endif

$(SHIM): c_src/telegram_tdlib_shim.cpp
	@mkdir -p "$(PRIV_DIR)"
	$(CXX) $(CXXFLAGS) "$<" -o "$@" $(LDFLAGS)
	@echo "telegram_tdlib: built shim -> $@"

clean:
	$(RM) "$(SHIM)"
