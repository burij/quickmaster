defmodule Tischlampe.Audio.Dyson do
  @moduledoc """
  Pure-Elixir port of the SWH "Dyson compressor" (LADSPA id 1403).

  Original algorithm by John S. Dyson, LADSPA wrapper by Steve Harris.
  This is a sample-by-sample, mono processor; run one instance per channel.
  It is a faithful transcription of `ladspa/dyson_compress_1403.xml`,
  including the `f_pow2` exponent approximation, so output matches the
  native plugin.

  Parameters and defaults match the LADSPA ports:

    * `peak_limit`  — dB, `-30..0`,  default `0.0`
    * `release_time`— seconds, `0..1`, default `0.0`
    * `cfrate`      — fast compression ratio, `0..1`, default `0.5`
    * `crate`       — compression ratio, `0..1`, default `0.5`

  State is a plain struct; the two filter chains (`rlevelsqn`, `rlevelsqe`)
  are fixed-size tuples and their scans are unrolled, which keeps the hot
  loop allocation-free.
  """

  import Bitwise

  @maxlevel 0.9
  @rlevelsq0_filter 0.001
  @rlevelsq1_filter 0.010
  @rlevelsq0f_filter 0.001
  @rlevelsqe_filter 0.001
  @rmastergain0_filter 0.000003
  @rpeakgain_filter 0.001
  @maxfastgain 3.0
  @maxslowgain 9.0
  @floorlevel 0.06
  @ln2r 1.442695041
  @poly_a 0.6960656421638072
  @poly_b 0.224494337302845
  @poly_c 0.07944023841053369
  # Original plugin never sets its `peaklimitdelay`, so this is always 0.
  @peaklimitdelay 0

  @type t :: %__MODULE__{}

  defstruct sample_rate: 44_100,
            params: %{peak_limit: 0.0, release_time: 0.0, cfrate: 0.5, crate: 0.5},
            targetlevel: @maxlevel,
            ndelay: 1000,
            delay: nil,
            rgainfilter: 0.0,
            rgain: 1.0,
            rlevelsq0: 0.0,
            rlevelsq1: 0.0,
            rlevelsqn: nil,
            rlevelsqe: nil,
            rmastergain0: 1.0,
            rpeakgain0: 1.0,
            rpeakgain1: 1.0,
            rpeaklimitdelay: 0,
            lastrgain: 1.0,
            mingain: 10_000.0,
            maxgain: 0.0,
            extra_maxlevel: 0.0

  @doc "Fresh instance for `sample_rate` and `params`."
  @spec new(number(), map()) :: t()
  def new(sample_rate, params) do
    # #define RLEVELSQ0FFILTER .001 -> ndelay = trunc(1/0.001)
    ndelay = trunc(1.0 / @rlevelsq0f_filter)

    %__MODULE__{
      sample_rate: sample_rate,
      params: params,
      targetlevel: @maxlevel * db_co(params.peak_limit),
      ndelay: ndelay,
      # Fixed delay of ndelay-1 samples; :queue keeps push/pop amortized O(1).
      delay: :queue.from_list(List.duplicate(0.0, ndelay - 1)),
      rgainfilter: 1.0 / (:erlang.max(params.release_time, 1.0e-7) * sample_rate),
      rlevelsqn: zeros(12),
      rlevelsqe: zeros(17)
    }
  end

  @doc "Process a float list, returning `{outputs, state}`."
  @spec process(t(), [float()]) :: {[float()], t()}
  def process(state, samples) do
    {state, out} = process_binary(state, f32_binary(samples))
    {for(<<f::float-little-32 <- out>>, do: f), state}
  end

  @doc "Process a raw little-endian f32 PCM binary, returning `{state, out}`."
  @spec process_binary(t(), binary()) :: {t(), binary()}
  def process_binary(state, bin) do
    for <<f::float-little-32 <- bin>>, reduce: {state, <<>>} do
      {s, acc} ->
        {y, s} = step(s, f)
        {s, <<acc::binary, y::float-little-32>>}
    end
  end

  @doc "Advance one sample."
  @spec step(t(), float()) :: {float(), t()}
  def step(s, input) do
    levelsq0 = 2.0 * input * input

    {{:value, d}, delay} = :queue.out(:queue.in(input, s.delay))
    s = %{s | delay: delay}

    rlevelsq0 =
      if levelsq0 > s.rlevelsq0 do
        levelsq0 * @rlevelsq0f_filter + s.rlevelsq0 * (1.0 - @rlevelsq0f_filter)
      else
        levelsq0 * @rlevelsq0_filter + s.rlevelsq0 * (1.0 - @rlevelsq0_filter)
      end

    s = %{s | rlevelsq0: rlevelsq0}

    if rlevelsq0 <= @floorlevel * @floorlevel do
      tail(s, d)
    else
      tail(agc(s, rlevelsq0), d)
    end
  end

  # The AGC block is skipped entirely (goto skipagc) when the level is low.
  defp agc(s, rlevelsq0) do
    rlevelsq1 =
      if rlevelsq0 > s.rlevelsq1 do
        rlevelsq0
      else
        rlevelsq0 * @rlevelsq1_filter + s.rlevelsq1 * (1.0 - @rlevelsq1_filter)
      end

    {rlevelsqn, n_last} = scan_hold(s.rlevelsqn, rlevelsq1, @rlevelsq1_filter)
    {rlevelsqe, levelsqe} = scan_leak(s.rlevelsqe, n_last, @rlevelsqe_filter)

    gain0 = s.targetlevel / :math.sqrt(levelsqe)
    crate = s.params.crate

    gain =
      if crate < 0.99 do
        if crate == 0.50, do: :math.sqrt(gain0), else: f_exp(:math.log(gain0) * crate)
      else
        gain0
      end

    rgain =
      if gain < s.rgain do
        gain * @rlevelsqe_filter / 2.0 + s.rgain * (1.0 - @rlevelsqe_filter / 2.0)
      else
        gain * s.rgainfilter + s.rgain * (1.0 - s.rgainfilter)
      end

    %{
      s
      | rlevelsq1: rlevelsq1,
        rlevelsqn: rlevelsqn,
        rlevelsqe: rlevelsqe,
        rgain: rgain,
        lastrgain: min(rgain, gain)
    }
  end

  defp tail(s, d) do
    tgain = s.lastrgain

    fastgain =
      cond do
        tgain > @maxfastgain -> @maxfastgain
        tgain < 0.0001 -> 0.0001
        true -> tgain
      end

    qgain = f_exp(:math.log(fastgain) * s.params.cfrate)

    tslowgain = tgain / qgain
    tslowgain = min(tslowgain, @maxslowgain)

    rmastergain0 =
      if tslowgain < s.rmastergain0 do
        tslowgain
      else
        tslowgain * @rmastergain0_filter + (1.0 - @rmastergain0_filter) * s.rmastergain0
      end

    npeakgain = rmastergain0 * qgain
    new = d * npeakgain
    an = abs(new)
    nrgain = if an >= @maxlevel, do: @maxlevel / an, else: 1.0
    ngsq = nrgain * nrgain

    {rpeakgain0, rpeaklimitdelay} =
      if ngsq <= s.rpeakgain0 do
        {ngsq, @peaklimitdelay}
      else
        if s.rpeaklimitdelay == 0 do
          tnrgain = min(nrgain, 1.0)

          {tnrgain * @rpeakgain_filter + (1.0 - @rpeakgain_filter) * s.rpeakgain0,
           s.rpeaklimitdelay}
        else
          {s.rpeakgain0, s.rpeaklimitdelay}
        end
      end

    {rpeakgain1, rpeaklimitdelay} =
      if rpeakgain0 <= s.rpeakgain1 do
        {rpeakgain0, @peaklimitdelay}
      else
        if rpeaklimitdelay == 0 do
          {@rpeakgain_filter * rpeakgain0 + (1.0 - @rpeakgain_filter) * s.rpeakgain1,
           rpeaklimitdelay}
        else
          {s.rpeakgain1, rpeaklimitdelay - 1}
        end
      end

    sqrtrpeakgain = :math.sqrt(rpeakgain1)
    totalgain = npeakgain * sqrtrpeakgain
    output = new * sqrtrpeakgain

    s = %{
      s
      | rmastergain0: rmastergain0,
        rpeakgain0: rpeakgain0,
        rpeakgain1: rpeakgain1,
        rpeaklimitdelay: rpeaklimitdelay,
        mingain: min(s.mingain, totalgain),
        maxgain: max(s.maxgain, totalgain),
        extra_maxlevel: max(s.extra_maxlevel, output)
    }

    {output, s}
  end

  # rlevelsqn[i+1] = hold(rlevelsqn[i], rlevelsqn[i+1]); unrolled.
  # `hold(prev, x)` = if prev > x, do: prev, else: prev*r + x*(1-r)
  defp scan_hold(t, n0, r) do
    r1 = 1.0 - r
    o1 = elem(t, 1)
    p1 = if n0 > o1, do: n0, else: n0 * r + o1 * r1
    o2 = elem(t, 2)
    p2 = if p1 > o2, do: p1, else: p1 * r + o2 * r1
    o3 = elem(t, 3)
    p3 = if p2 > o3, do: p2, else: p2 * r + o3 * r1
    o4 = elem(t, 4)
    p4 = if p3 > o4, do: p3, else: p3 * r + o4 * r1
    o5 = elem(t, 5)
    p5 = if p4 > o5, do: p4, else: p4 * r + o5 * r1
    o6 = elem(t, 6)
    p6 = if p5 > o6, do: p5, else: p5 * r + o6 * r1
    o7 = elem(t, 7)
    p7 = if p6 > o7, do: p6, else: p6 * r + o7 * r1
    o8 = elem(t, 8)
    p8 = if p7 > o8, do: p7, else: p7 * r + o8 * r1
    o9 = elem(t, 9)
    p9 = if p8 > o9, do: p8, else: p8 * r + o9 * r1
    o10 = elem(t, 10)
    p10 = if p9 > o10, do: p9, else: p9 * r + o10 * r1
    o11 = elem(t, 11)
    p11 = if p10 > o11, do: p10, else: p10 * r + o11 * r1
    {{n0, p1, p2, p3, p4, p5, p6, p7, p8, p9, p10, p11}, p11}
  end

  # Leaky-max scan with shrinking coefficient; unrolled.
  defp scan_leak(t, lv0, ef) do
    p1 = lv0 * ef + elem(t, 1) * (1.0 - ef)
    m1 = max(lv0, p1)
    ef = ef / 1.5
    p2 = p1 * ef + elem(t, 2) * (1.0 - ef)
    m2 = max(m1, p2)
    ef = ef / 1.5
    p3 = p2 * ef + elem(t, 3) * (1.0 - ef)
    m3 = max(m2, p3)
    ef = ef / 1.5
    p4 = p3 * ef + elem(t, 4) * (1.0 - ef)
    m4 = max(m3, p4)
    ef = ef / 1.5
    p5 = p4 * ef + elem(t, 5) * (1.0 - ef)
    m5 = max(m4, p5)
    ef = ef / 1.5
    p6 = p5 * ef + elem(t, 6) * (1.0 - ef)
    m6 = max(m5, p6)
    ef = ef / 1.5
    p7 = p6 * ef + elem(t, 7) * (1.0 - ef)
    m7 = max(m6, p7)
    ef = ef / 1.5
    p8 = p7 * ef + elem(t, 8) * (1.0 - ef)
    m8 = max(m7, p8)
    ef = ef / 1.5
    p9 = p8 * ef + elem(t, 9) * (1.0 - ef)
    m9 = max(m8, p9)
    ef = ef / 1.5
    p10 = p9 * ef + elem(t, 10) * (1.0 - ef)
    m10 = max(m9, p10)
    ef = ef / 1.5
    p11 = p10 * ef + elem(t, 11) * (1.0 - ef)
    m11 = max(m10, p11)
    ef = ef / 1.5
    p12 = p11 * ef + elem(t, 12) * (1.0 - ef)
    m12 = max(m11, p12)
    ef = ef / 1.5
    p13 = p12 * ef + elem(t, 13) * (1.0 - ef)
    m13 = max(m12, p13)
    ef = ef / 1.5
    p14 = p13 * ef + elem(t, 14) * (1.0 - ef)
    m14 = max(m13, p14)
    ef = ef / 1.5
    p15 = p14 * ef + elem(t, 15) * (1.0 - ef)
    m15 = max(m14, p15)
    ef = ef / 1.5
    p16 = p15 * ef + elem(t, 16) * (1.0 - ef)
    m16 = max(m15, p16)

    {{lv0, p1, p2, p3, p4, p5, p6, p7, p8, p9, p10, p11, p12, p13, p14, p15, p16}, m16}
  end

  defp db_co(g) when g > -90.0, do: :math.pow(10.0, g * 0.05)
  defp db_co(_), do: 0.0

  defp zeros(n), do: List.to_tuple(List.duplicate(0.0, n))

  defp f32_binary(samples) do
    for f <- samples, into: <<>>, do: <<f::float-little-32>>
  end

  # f_exp(x) = f_pow2(x * LN2R), the music-dsp pow2 approximation used by the
  # original plugin. The 32-bit float encoding rounds for us, so we skip
  # explicit float32 casts on the intermediate doubles.
  defp f_exp(x), do: f_pow2(x * @ln2r)

  defp f_pow2(x) do
    <<txi::signed-32>> = <<x - 0.5 + 12_582_912.0::float-32>>
    lx = txi - 0x4B400000
    dx = x - lx
    poly = 1.0 + dx * (@poly_a + dx * (@poly_b + dx * @poly_c))
    <<pi::signed-32>> = <<poly::float-32>>
    <<result::float-32>> = <<pi + (lx <<< 23)::signed-32>>
    result
  end
end
