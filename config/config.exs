import Config

# SPK kernels to load at startup.
# de440s.bsp covers planets + Sun/Moon.
# Asteroid kernels (center=Sun/10) are generated via `mix eph.generate_kernel NAIF_ID`.
# Missing files emit a Logger.warning and are skipped — safe to deploy without asteroid kernels.
config :eph_core, :spk_kernels, [
  "de440s.bsp",
  "asteroids/2000001.bsp",
  "asteroids/2000002.bsp",
  "asteroids/2000003.bsp",
  "asteroids/2000004.bsp",
  "asteroids/2002060.bsp"
]
