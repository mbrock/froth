#include <erl_nif.h>
#include <speex/speex_resampler.h>
#include <string.h>

typedef struct {
    SpeexResamplerState *st;
    spx_uint32_t in_rate;
    spx_uint32_t out_rate;
    int channels;
} ResamplerRes;

static ErlNifResourceType *RESAMPLER_TYPE;

static void resampler_dtor(ErlNifEnv *env, void *obj) {
    (void)env;
    ResamplerRes *res = (ResamplerRes *)obj;
    if (res->st) {
        speex_resampler_destroy(res->st);
        res->st = NULL;
    }
}

static int load(ErlNifEnv *env, void **priv, ERL_NIF_TERM load_info) {
    (void)priv;
    (void)load_info;
    RESAMPLER_TYPE = enif_open_resource_type(
        env, NULL, "speex_resampler", resampler_dtor, ERL_NIF_RT_CREATE, NULL);
    if (!RESAMPLER_TYPE) return -1;
    return 0;
}

/* new(channels, in_rate, out_rate, quality) -> {:ok, ref} | {:error, reason} */
static ERL_NIF_TERM nif_new(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    int channels, quality;
    unsigned int in_rate, out_rate;

    if (!enif_get_int(env, argv[0], &channels) ||
        !enif_get_uint(env, argv[1], &in_rate) ||
        !enif_get_uint(env, argv[2], &out_rate) ||
        !enif_get_int(env, argv[3], &quality)) {
        return enif_make_badarg(env);
    }

    int err;
    SpeexResamplerState *st = speex_resampler_init(
        channels, in_rate, out_rate, quality, &err);

    if (err != RESAMPLER_ERR_SUCCESS || !st) {
        return enif_make_tuple2(env,
            enif_make_atom(env, "error"),
            enif_make_int(env, err));
    }

    ResamplerRes *res = enif_alloc_resource(RESAMPLER_TYPE, sizeof(ResamplerRes));
    res->st = st;
    res->in_rate = in_rate;
    res->out_rate = out_rate;
    res->channels = channels;

    ERL_NIF_TERM ref = enif_make_resource(env, res);
    enif_release_resource(res);

    return enif_make_tuple2(env, enif_make_atom(env, "ok"), ref);
}

/* process(ref, input_binary) -> {:ok, output_binary} */
static ERL_NIF_TERM nif_process(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ResamplerRes *res;
    ErlNifBinary in_bin;

    if (!enif_get_resource(env, argv[0], RESAMPLER_TYPE, (void **)&res) ||
        !enif_inspect_binary(env, argv[1], &in_bin)) {
        return enif_make_badarg(env);
    }

    /* 16-bit samples, interleaved channels */
    spx_uint32_t in_frames = (spx_uint32_t)(in_bin.size / (2 * res->channels));

    /* worst-case output size */
    spx_uint32_t out_frames = in_frames * res->out_rate / res->in_rate + 256;

    ErlNifBinary out_bin;
    size_t out_buf_size = out_frames * 2 * res->channels;
    if (!enif_alloc_binary(out_buf_size, &out_bin)) {
        return enif_make_tuple2(env,
            enif_make_atom(env, "error"),
            enif_make_atom(env, "alloc"));
    }

    spx_uint32_t in_len = in_frames;
    spx_uint32_t out_len = out_frames;

    int err = speex_resampler_process_interleaved_int(
        res->st,
        (const spx_int16_t *)in_bin.data, &in_len,
        (spx_int16_t *)out_bin.data, &out_len);

    if (err != RESAMPLER_ERR_SUCCESS) {
        enif_release_binary(&out_bin);
        return enif_make_tuple2(env,
            enif_make_atom(env, "error"),
            enif_make_int(env, err));
    }

    size_t actual_size = out_len * 2 * res->channels;
    if (actual_size < out_buf_size) {
        enif_realloc_binary(&out_bin, actual_size);
    }

    return enif_make_tuple2(env,
        enif_make_atom(env, "ok"),
        enif_make_binary(env, &out_bin));
}

static ErlNifFunc nif_funcs[] = {
    {"nif_new", 4, nif_new, 0},
    {"nif_process", 2, nif_process, 0}
};

ERL_NIF_INIT(Elixir.Froth.SpeexResample, nif_funcs, load, NULL, NULL, NULL)
