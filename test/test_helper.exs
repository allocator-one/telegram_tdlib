# Integration tests start the real Port + C++ shim and require TDLib (libtdjson)
# to be installed/built; they are excluded by default. Run them with:
#   mix test --include integration
ExUnit.start(exclude: [:integration])
