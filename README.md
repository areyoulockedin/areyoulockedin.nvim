# areyoulockedin.nvim
areyoulocked.in is a coding activity tracker. this neovim extension keeps track of the time you spend coding and puts you on the leaderboard at areyoulocked.in

Use `:AYLISetSessionKey` to set your session key.

lazy:

```lua
return {
  "areyoulockedin/areyoulockedin.nvim",
  dependencies = { "nvim-lua/plenary.nvim" },
  event = "VeryLazy",
  config = function()
    require("areyoulockedin").setup({
      session_key = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
    })
  end,
}
```
