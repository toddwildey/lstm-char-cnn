local LSTMTDNN = {}

local ok, cunn = pcall(require, 'fbcunn')
LookupTable = nn.LookupTable

function LSTMTDNN.lstmtdnn(
        rnn_size,           -- rnn_size = dimensionality of hidden layers
        n,                  -- n = number of layers
        dropout,            -- dropout = dropout probability
        word_vocab_size,    -- word_vocab_size = num words in the vocab    
        char_vocab_size,    -- char_vocab_size = num chars in the character vocab
        char_vec_size,      -- char_vec_size = dimensionality of char embeddings
        feature_maps,       -- feature_maps = table of feature map sizes for each kernel width
        kernels,            -- kernels = table of kernel widths
        max_word_l,         -- max_word_l = max length of a word
        batch_norm,         -- batch_norm = 1 if batches should be normalized
        highway_layers,     -- highway_layers = number of highway layers to use, if any
        hsm                 -- hsm = # of hierarchical softmax layers
)
    dropout = dropout or 0 

    -- there will be 2*n+1 inputs if using words or chars, 
    -- otherwise there will be 2*n + 2 inputs   
    local char_vec_layer, x, input_size_L, char_vec
    local highway_layers = highway_layers or 0
    local inputs = {}

    table.insert(inputs, nn.Identity()()) -- batch_size x word length (char indices)
    char_vec_layer = LookupTable(char_vocab_size, char_vec_size)
    char_vec_layer.name = 'char_vecs' -- change name so we can refer to it easily later

    for L = 1,n do
        table.insert(inputs, nn.Identity()()) -- prev_c[L]
        table.insert(inputs, nn.Identity()()) -- prev_h[L]
    end

    local outputs = {}
    for L = 1,n do
        -- c,h from previous timesteps. offsets depend on if we are using both word/chars
        local prev_h = inputs[2 * L + 1]
        local prev_c = inputs[2 * L]

        -- the input to this layer
        if L == 1 then
            char_vec = char_vec_layer(inputs[1])
            local char_cnn = TDNN.tdnn(max_word_l, char_vec_size, feature_maps, kernels)
            char_cnn.name = 'cnn' -- change name so we can refer to it later

            local cnn_output = char_cnn(char_vec)
            input_size_L = torch.Tensor(feature_maps):sum()
            
            x = nn.Identity()(cnn_output)

            if batch_norm == 1 then 
                x = nn.BatchNormalization(0)(x)
            end

            if highway_layers > 0 then
                local highway_mlp = HighwayMLP.mlp(input_size_L, highway_layers)
                highway_mlp.name = 'highway'
                x = highway_mlp(x)
            end
        else 
            x = outputs[(L-1)*2] -- prev_h
            if dropout > 0 then
                x = nn.Dropout(dropout)(x) -- apply dropout, if any
            end

            input_size_L = rnn_size
        end

        -- evaluate the input sums at once for efficiency
        local i2h = nn.Linear(input_size_L, 4 * rnn_size)(x)
        local h2h = nn.Linear(rnn_size, 4 * rnn_size)(prev_h)
        local all_input_sums = nn.CAddTable()({i2h, h2h})
        
        local sigmoid_chunk = nn.Narrow(2, 1, 3*rnn_size)(all_input_sums)
        sigmoid_chunk = nn.Sigmoid()(sigmoid_chunk)
        local in_gate = nn.Narrow(2,1,rnn_size)(sigmoid_chunk)
        local out_gate = nn.Narrow(2, rnn_size+1, rnn_size)(sigmoid_chunk)
        local forget_gate = nn.Narrow(2, 2*rnn_size + 1, rnn_size)(sigmoid_chunk)
        local in_transform = nn.Tanh()(nn.Narrow(2,3*rnn_size + 1, rnn_size)(all_input_sums))

        -- perform the LSTM update
        local next_c = nn.CAddTable()({
            nn.CMulTable()({forget_gate, prev_c}),
            nn.CMulTable()({in_gate, in_transform})
        })

        -- gated cells form the output
        local next_h = nn.CMulTable()({out_gate, nn.Tanh()(next_c)})

        table.insert(outputs, next_c)
        table.insert(outputs, next_h)
    end

    -- set up the decoder
    local top_h = outputs[#outputs]
    if dropout > 0 then 
        top_h = nn.Dropout(dropout)(top_h) 
    else
        top_h = nn.Identity()(top_h) --to be compatiable with dropout=0 and hsm>1
    end

    if hsm > 0 then -- if HSM is used then softmax will be done later
        table.insert(outputs, top_h)
    else
        local proj = nn.Linear(rnn_size, word_vocab_size)(top_h)
        local logsoft = nn.LogSoftMax()(proj)
        table.insert(outputs, logsoft)
    end

    return nn.gModule(inputs, outputs)
end

return LSTMTDNN

