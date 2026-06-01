local Util = {}

Util.Connections = {}

function Util:AttachLimitToTextBox(textBox, limit)
    Util.Connections[textBox] = textBox:GetPropertyChangedSignal("Text"):Connect(function()
        if #textBox.Text > limit then
            textBox.Text = string.sub(textBox.Text, 1, limit)
        end
    end)

    return Util.Connections[textBox]
end

return Util