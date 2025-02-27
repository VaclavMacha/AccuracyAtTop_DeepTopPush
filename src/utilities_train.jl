using BenchmarkTools
using BSON
using CUDA
using Flux
using ProgressMeter
using Random
using StatsBase
using ValueHistories

using Base.Iterators: partition
using Flux: gpu
using Flux.Optimise: runall, update!, StopException, batchmemaybe
using Flux.Data: DataLoader
using Zygote: Params, gradient

# -------------------------------------------------------------------------------
# Data processing
# -------------------------------------------------------------------------------
function batch_provider(x, y, batchsize)
    neg = findall(vec(y) .== 0)
    pos = findall(vec(y) .== 1)

    n_neg = batchsize ÷ 2
    n_pos = batchsize - n_neg

    x_obs = ndims(x)
    y_obs = ndims(y)

    last_batch = sample(1:batchsize, batchsize; replace = false)

    function make_batch(; buffer = false)
        inds = vcat(
            sample(neg, n_neg; replace = length(neg) < n_neg),
            sample(pos, n_pos; replace = length(pos) < n_pos),
        )
        shuffle!(inds)
        if !ismissing(buffer)
            if buffer
                addind = AccuracyAtTop.BUFFER[].ind
                if 0 < addind <= batchsize
                    inds[end] = last_batch[addind]
                end
                last_batch .= inds
            end
        end
        return (getdim(x, x_obs, inds), getdim(y, y_obs, inds))
    end
    return make_batch
end

# -------------------------------------------------------------------------------
# Custom train!
# -------------------------------------------------------------------------------
function custom_train!(loss, ps, data, opt; cb = (args...) -> ())
  ps = Params(ps)
  cb = runall(cb)

  local loss_val

  for d in data
    try
      gs = gradient(ps) do
        loss_val = loss(batchmemaybe(d)...)
        return loss_val
      end
      update!(opt, ps, gs)
      cb(loss_val, batchmemaybe(d)...)
    catch ex
      if ex isa StopException
        break
      else
        rethrow(ex)
      end
    end
  end
end

# -------------------------------------------------------------------------------
# Callback function
# -------------------------------------------------------------------------------
Base.@kwdef mutable struct CallBack
    iters::Int
    epochlength::Int = iters
    title::String = "Training:"
    bar::Progress = Progress(iters, 5, title)
    showat::Int = 100
    showfunc::Function = (args...) -> []
    saveat::Int = 1000
    savefunc::Function = (args...) -> nothing
    counter::Int = 0
    usershows = []
    loss = History(Float32)
end

function CallBack(iters, epochlength = iters; kwargs...)
    return CallBack(; iters = iters, epochlength = epochlength, kwargs...)
end

function (c::CallBack)(loss_val, x, y)
    c.counter += 1
    push!(c.loss, c.counter, eltype(c.loss.values)(loss_val))

    if mod(c.counter, c.showat) == 0 || c.counter == 1
        c.usershows = c.showfunc(c)
    end
    if mod(c.counter, c.saveat) == 0
        c.savefunc(c, x, y)
    end
    next!(c.bar; showvalues = vcat(
        epochcounter(c),
        epochtimer(c),
        itercounter(c),
        itertimer(c),
        c.usershows
    ))
    return
end

function itercounter(c::CallBack)
    return ("Iteration", string(c.counter, "/", c.iters))
end

function itertimer(c::CallBack)
    tm = round((c.bar.tlast - c.bar.tinit)/c.bar.counter; sigdigits = 2)
    return ("Average time per iteration", string(tm, "s"))
end

function epochcounter(c::CallBack)
    epoch = floor(Int, c.counter/c.epochlength)
    maxepoch = floor(Int, c.iters/c.epochlength)
    return maxepoch <= 1 ? [] : ("Epoch", string(epoch, "/", maxepoch))
end

function epochtimer(c::CallBack)
    tm = round(c.epochlength*(c.bar.tlast - c.bar.tinit)/c.bar.counter; sigdigits = 2)
    return ("Average time per epoch", string(tm, "s"))
end

# -------------------------------------------------------------------------------
# Saving functions
# -------------------------------------------------------------------------------
function save_simulation(
    c::CallBack,
    dataset_settings::Dict,
    train_settings_in::Dict,
    model_settings::Dict,
    model,
    x,
    y,
)

    savedir = modeldir(dataset_settings, train_settings_in, model_settings)

    train_settings = deepcopy(train_settings_in)
    train_settings[:epochs] = floor(Int, c.counter/c.epochlength)
    train_settings[:epochlength] = c.epochlength
    train_settings[:iters] = c.counter

    tm = (c.bar.tlast - c.bar.tinit)/c.bar.counter

    simulation = Dict(
        :dataset_settings => deepcopy(dataset_settings),
        :train_settings => deepcopy(train_settings),
        :model_settings => deepcopy(model_settings),
        :time_per_iter => tm,
        :time_per_epoch => tm * c.epochlength,
        :model => cpu(model),
        :loss => c.loss.values,
        :minibatch => Dict(
            :targets => cpu(vec(y)),
            :scores => cpu(compute_scores(model, x)),
        ),
    )

    # save
    model_dict = deepcopy(model_settings)
    model_dict[:epochs] = simulation[:train_settings][:epochs]
    model_dict[:iters] = simulation[:train_settings][:iters]

    isdir(savedir) || mkpath(savedir)
    bson(joinpath(savedir, simulation_name(train_settings[:epochs])), simulation)
    return
end

function save_simulation_tfco(
    dataset_settings::Dict,
    train_settings_in::Dict,
    model_settings::Dict,
    results,
    y_train,
    y_test,
)

    savedir = modeldir(dataset_settings, train_settings_in, model_settings)

    train_settings = deepcopy(train_settings_in)
    train_settings[:iters] = results["iters"]
    tm = results["tm"]

    simulation = Dict(
        :dataset_settings => deepcopy(dataset_settings),
        :train_settings => deepcopy(train_settings),
        :model_settings => deepcopy(model_settings),
        :time_per_iter => tm / train_settings[:iters],
        :time_per_epoch => tm / train_settings[:epochs],
        :train => Dict(
            :targets => vec(y_train),
            :scores => vec(results["s_train"]),
            :loss => results["loss_train"],
        ),
        :test => Dict(
            :targets => vec(y_test),
            :scores => vec(results["s_test"]),
            :loss => results["loss_test"],
        ),
    )

    # save
    model_dict = deepcopy(model_settings)
    model_dict[:epochs] = simulation[:train_settings][:epochs]
    model_dict[:iters] = simulation[:train_settings][:iters]

    isdir(savedir) || mkpath(savedir)
    bson(joinpath(savedir, simulation_name(model_dict[:epochs])), simulation)
    return
end

# -------------------------------------------------------------------------------
# Runing simulations
# -------------------------------------------------------------------------------
function run_simulations(Dataset_Settings, Train_Settings, Model_Settings; nepochs_save = 1)
    for dataset_settings in dict_list_simple(Dataset_Settings)
        @unpack dataset, posclass = dataset_settings
        @info "Dataset: $(dataset), positive class label: $(posclass)"

        labelmap(y) = y in posclass
        (x_train, y_train), (x_test, y_test) = load(dataset; labelmap = labelmap)

        for train_settings in dict_list_simple(Train_Settings)
            @unpack batchsize, epochs, seed = train_settings
            @info "Batchsize: $(batchsize), seed: $(seed)"

            epochlength = length(y_train) ÷ batchsize
            iters = epochs * epochlength
            make_batch = batch_provider(x_train, y_train, batchsize)

            for model_settings in dict_list_simple(Model_Settings)
                @unpack type, arg, surrogate, reg, buffer = model_settings
                model_settings[:seed] = seed

                # create model
                model = build_network(dataset; seed = seed) |> gpu
                objective = build_loss(type, arg, surrogate, reg)
                pars = params(model)

                loss(x, y) = objective(x, y, model, pars)

                # create callback
                savefunc(c, x, y) = save_simulation(
                    c,
                    dataset_settings,
                    train_settings,
                    model_settings,
                    model,
                    x,
                    y,
                )

                cb = CallBack(
                    title = string(string(type), ": "),
                    iters = iters,
                    epochlength = epochlength;
                    saveat = nepochs_save * epochlength,
                    savefunc = savefunc,
                )

                # training
                @info "Bacth preparation:"
                Random.seed!(seed)
                batches = (gpu(make_batch(; buffer = buffer)) for iter in 1:iters)

                @unpack optimiser, steplength = train_settings
                opt = optimiser(steplength)

                custom_train!(loss, pars, batches, opt; cb = cb)
            end
        end
    end
end

function run_benchmark(Dataset_Settings, Train_Settings, Model_Settings)
    for dataset_settings in dict_list_simple(Dataset_Settings)
        @unpack dataset, posclass = dataset_settings
        @info "Dataset: $(dataset), positive class label: $(posclass)"

        labelmap = (y) -> y == posclass
        (x_train, y_train), ~ = load(dataset; labelmap = labelmap)


        for train_settings in dict_list_simple(Train_Settings)
            @unpack batchsize, iters = train_settings
            @info "Batchsize: $(batchsize), iters: $(iters)"

            epochlength = length(y_train) ÷ batchsize
            make_batch = batch_provider(x_train, y_train, batchsize)

            for model_settings in dict_list_simple(Model_Settings)
                @unpack type, arg, surrogate, reg, buffer = model_settings

                # create model
                model = build_network(dataset; seed = 1) |> gpu
                objective = build_loss(type, arg, surrogate, reg)
                pars = params(model)

                loss(x, y) = objective(x, y, model, pars)

                # training
                @info "Model: $(type)"
                batches = [gpu(make_batch(; buffer = buffer)) for iter in 1:iters] |> gpu

                @unpack optimiser, steplength = train_settings
                opt = optimiser(steplength)

                # precompile
                Flux.train!(loss, pars, (make_batch(; buffer = buffer) for iter in 1:5), opt)

                # run benchmark
                b = @benchmark Flux.train!($loss, $pars, $batches, $opt)
                d = Dict(:times => b.times .* 1e-9, :epochlength => epochlength, :iters_in_run => iters)

                savedir = datadir(
                    "benchmarks",
                    dataset_savename(dataset_settings),
                    train_savename(train_settings),
                )
                file_name = string(model_savename(model_settings), ".bson")

                mkpath(savedir)
                BSON.bson(joinpath(savedir, file_name), d)
            end
        end
    end
end
