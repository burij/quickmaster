ffmpeg? = Quickmaster.Audio.FFmpeg.available?()
mmpeg? = Quickmaster.Audio.Player.available?()

exclude =
  if(ffmpeg?, do: [], else: [:ffmpeg]) ++
    if(mmpeg?, do: [], else: [:mpv])

Application.ensure_all_started(:quickmaster)
ExUnit.start(exclude: exclude)
