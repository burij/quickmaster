ffmpeg? = Quickmaster.Audio.FFmpeg.available?()
mmpeg? = Quickmaster.Audio.Player.available?()

exclude =
  if(ffmpeg?, do: [], else: [:ffmpeg]) ++
    if(mmpeg?, do: [], else: [:mpv])

ExUnit.start(exclude: exclude)
