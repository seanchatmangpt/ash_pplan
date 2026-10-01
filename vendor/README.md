# vendor

## reactor_process 0.5.0

Unpacked from Hex (`mix hex.package fetch reactor_process 0.5.0 --unpack`). The only change is
`mix.exs`: `{:reactor, "== 1.0.6"}` -> `{:reactor, "~> 1.0"}`, because upstream's exact pin
conflicts with the current `reactor` 1.0.7. Licences are retained in `LICENSES/`. Drop this
directory and use the Hex package once upstream relaxes the pin.
