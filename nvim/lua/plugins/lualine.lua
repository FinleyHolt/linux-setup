return {

    'nvim-lualine/lualine.nvim',

    config = function()

        require('lualine').setup {

            options = {

                theme = 'auto'

            },

            sections = {

                -- Click "Files" to open or close the file panel
                lualine_a = {
                    { function() return '󰙅 Files' end, on_click = function() require('filetree').toggle() end },
                    'mode',
                },

            },

        }

    end

}

