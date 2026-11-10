# Historical Phim4K integration — excluded from the application

These files are reference material from baseline `ea2f8c0`, not a supported
runtime or runnable test target after the Aether migration. XcodeGen only builds
`AnyAnime`, so none of these providers, directory credentials, Core routes or
resolvers ship. Historical combined parser/provider tests and smoke harness are
retained here to explain old fixtures; public NguonC/KKPhim and shared transport
regressions remain in `Tests`.

The shared media probe, transport redirect policy and relay naming stay in
`AnyAnime` under their historical filenames. The MKV/audio/subtitle, wrapped HLS,
Range, Anime and AI fixtures remain active. `Tests/relay-hls-smoke.sh` exercises
the HLS fixture using the public-provider test adapter instead of Phim4K.

Do not run the historical workflow or scripts as current deployment instructions.
Original provider contracts and result files do not establish Aether behavior.
