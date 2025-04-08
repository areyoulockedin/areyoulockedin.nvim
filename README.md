# areyoulockedin.nvim

lazy (wip):

```lua
return {
  "voltycodes/areyoulockedin.nvim",
  dependencies = { "nvim-lua/plenary.nvim" },
  event = "VeryLazy",
  config = function()
    require("areyoulockedin").setup({
      session_key = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
    })
  end,
}
```
