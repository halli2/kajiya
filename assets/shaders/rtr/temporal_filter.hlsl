#include "../inc/samplers.hlsl"
#include "../inc/uv.hlsl"
#include "../inc/frame_constants.hlsl"
#include "../inc/color.hlsl"
#include "../inc/bilinear.hlsl"
#include "../inc/soft_color_clamp.hlsl"
#include "rtr_settings.hlsl"

#include "../inc/working_color_space.hlsl"

// Use this after tweaking all the spec.
#define linear_to_working linear_rgb_to_crunched_luma_chroma
#define working_to_linear crunched_luma_chroma_to_linear_rgb

//#define linear_to_working linear_rgb_to_linear_rgb
//#define working_to_linear linear_rgb_to_linear_rgb

#define USE_DUAL_REPROJECTION 1
#define USE_NEIGHBORHOOD_CLAMP 1

[[vk::binding(0)]] Texture2D<float4> input_tex;
[[vk::binding(1)]] Texture2D<float4> history_tex;
[[vk::binding(2)]] Texture2D<float> depth_tex;
[[vk::binding(3)]] Texture2D<float> ray_len_tex;
[[vk::binding(4)]] Texture2D<float4> reprojection_tex;
[[vk::binding(5)]] Texture2D<float> refl_restir_invalidity_tex;
[[vk::binding(6)]] RWTexture2D<float4> output_tex;
[[vk::binding(7)]] cbuffer _ {
    float4 output_tex_size;
};


[numthreads(8, 8, 1)]
void main(uint2 px: SV_DispatchThreadID) {
    #if 0
        output_tex[px] = float4(ray_len_tex[px].xxx * 0.1, 1);
        return;
    #elif !RTR_USE_TEMPORAL_FILTERS
        output_tex[px] = float4(input_tex[px].rgb, 128);
        return;
    #endif

    const float4 center = linear_to_working(input_tex[px]);

    float refl_ray_length = clamp(ray_len_tex[px], 0, 1e3);

    // TODO: run a small edge-aware soft-min filter of ray length.
    // The `WaveActiveMin` below improves flat rough surfaces, but is not correct across discontinuities.
    //refl_ray_length = WaveActiveMin(refl_ray_length);
    
    float2 uv = get_uv(px, output_tex_size);
    
    const float center_depth = depth_tex[px];
    const ViewRayContext view_ray_context = ViewRayContext::from_uv_and_depth(uv, center_depth);
    const float3 reflector_vs = view_ray_context.ray_hit_vs();
    const float3 reflection_hit_vs = reflector_vs + view_ray_context.ray_dir_vs() * refl_ray_length;

    const float4 reflection_hit_cs = mul(frame_constants.view_constants.view_to_sample, float4(reflection_hit_vs, 1));
    const float4 prev_hit_cs = mul(frame_constants.view_constants.clip_to_prev_clip, reflection_hit_cs);
    float2 hit_prev_uv = cs_to_uv(prev_hit_cs.xy / prev_hit_cs.w);

    const float4 prev_reflector_cs = mul(frame_constants.view_constants.clip_to_prev_clip, view_ray_context.ray_hit_cs);
    const float2 reflector_prev_uv = cs_to_uv(prev_reflector_cs.xy / prev_reflector_cs.w);

    float4 reproj = reprojection_tex[px];

    const float2 reflector_move_rate = min(1.0, length(reproj.xy) / length(reflector_prev_uv - uv));
    hit_prev_uv = lerp(uv, hit_prev_uv, reflector_move_rate);

    const uint quad_reproj_valid_packed = uint(reproj.z * 15.0 + 0.5);
    const float4 quad_reproj_valid = (quad_reproj_valid_packed & uint4(1, 2, 4, 8)) != 0;

    const float4 history_mult = float4((frame_constants.pre_exposure_delta).xxx, 1);

    float4 history0 = 0.0;
    float history0_valid = 1;
    #if 0
        history0 = linear_to_working(history_tex.SampleLevel(sampler_lnc, uv + reproj.xy, 0) * history_mult);
    #else
        if (0 == quad_reproj_valid_packed) {
            // Everything invalid
            history0_valid = 0;
        } else if (15 == quad_reproj_valid_packed) {
            history0 = history_tex.SampleLevel(sampler_lnc, uv + reproj.xy, 0) * history_mult;
        } else {
            float4 quad_reproj_valid = (quad_reproj_valid_packed & uint4(1, 2, 4, 8)) != 0;

            const Bilinear bilinear = get_bilinear_filter(uv + reproj.xy, output_tex_size.xy);
            float4 s00 = history_tex[int2(bilinear.origin) + int2(0, 0)] * history_mult;
            float4 s10 = history_tex[int2(bilinear.origin) + int2(1, 0)] * history_mult;
            float4 s01 = history_tex[int2(bilinear.origin) + int2(0, 1)] * history_mult;
            float4 s11 = history_tex[int2(bilinear.origin) + int2(1, 1)] * history_mult;
            float4 weights = get_bilinear_custom_weights(bilinear, quad_reproj_valid);

            if (dot(weights, 1.0) > 1e-5) {
                history0 = apply_bilinear_custom_weights(s00, s10, s01, s11, weights);
            } else {
                // Invalid, but we have to return something.
                history0 = (s00 + s10 + s01 + s11) / 4;
            }
        }
        history0 = linear_to_working(history0);
    #endif

    float4 history1 = linear_to_working(history_tex.SampleLevel(sampler_lnc, hit_prev_uv, 0) * history_mult);
    float history1_valid = quad_reproj_valid_packed == 15;

    float4 history0_reproj = reprojection_tex.SampleLevel(sampler_lnc, uv + reproj.xy, 0);
    float4 history1_reproj = reprojection_tex.SampleLevel(sampler_lnc, hit_prev_uv, 0);


	float4 vsum = 0.0.xxxx;
	float4 vsum2 = 0.0.xxxx;
	float wsum = 0.0;

	const int k = 1;
    for (int y = -k; y <= k; ++y) {
        for (int x = -k; x <= k; ++x) {
            const int2 sample_px = px + int2(x, y) * 1;
            const float sample_depth = depth_tex[sample_px];

            float4 neigh = linear_to_working(input_tex[sample_px]);
			float w = 1;//exp(-3.0 * float(x * x + y * y) / float((k+1.) * (k+1.)));

            w *= exp2(-200.0 * abs(/*center_normal_vs.z **/ (center_depth / sample_depth - 1.0)));

			vsum += neigh * w;
			vsum2 += neigh * neigh * w;
			wsum += w;
        }
    }

	float4 ex = vsum / wsum;
	float4 ex2 = vsum2 / wsum;
	//float4 dev = sqrt(max(0.0.xxxx, ex2 - ex * ex));
    //float4 dev = sqrt(max(0.1 * ex, ex2 - ex * ex));
    float4 dev = sqrt(max(0.0.xxxx, ex2 - ex * ex));
    //dev = max(dev, 0.1);

    float reproj_validity_dilated = reproj.z;
    /*#if 1
        {
         	const int k = 2;
            for (int y = -k; y <= k; ++y) {
                for (int x = -k; x <= k; ++x) {
                    reproj_validity_dilated = min(reproj_validity_dilated, reprojection_tex[px + 2 * int2(x, y)].z);
                }
            }
        }
    #else
        reproj_validity_dilated = min(reproj_validity_dilated, WaveReadLaneAt(reproj_validity_dilated, WaveGetLaneIndex() ^ 1));
        reproj_validity_dilated = min(reproj_validity_dilated, WaveReadLaneAt(reproj_validity_dilated, WaveGetLaneIndex() ^ 8));
    #endif*/

    const float restir_invalidity = refl_restir_invalidity_tex[px / 2];
    //reproj_validity_dilated *= 1.0 - 0.5 * restir_invalidity;

    float box_size = 1;
    //const float n_deviations = 1;
    const float n_deviations = 1.25 * (1.0 - 0.5 * restir_invalidity);
    //const float n_deviations = reproj_validity_dilated;
    //const float n_deviations = 1 * lerp(2.0, 0.5, saturate(20.0 * length(reproj.xy))) * reproj_validity_dilated;
    //const float n_deviations = 5 * reproj_validity_dilated;

	//float4 nmin = lerp(center, ex, box_size * box_size) - dev * box_size * n_deviations;
	//float4 nmax = lerp(center, ex, box_size * box_size) + dev * box_size * n_deviations;
	float4 nmin = center - dev * box_size * n_deviations;
	float4 nmax = center + dev * box_size * n_deviations;

    
    float h0diff = length(history0.xyz - ex.xyz);
    float h1diff = length(history1.xyz - ex.xyz);
    float hdiff_scl = max(1e-10, max(h0diff, h1diff));

#if USE_DUAL_REPROJECTION
    float h0_score = exp2(-100 * min(1, h0diff / hdiff_scl)) * history0_valid;
    float h1_score = exp2(-100 * min(1, h1diff / hdiff_scl)) * history1_valid;
#else
    float h0_score = 0;
    float h1_score = 1;
#endif

    const float score_sum = h0_score + h1_score;
    if (score_sum > 1e-50) {
        h0_score /= score_sum;
        h1_score /= score_sum;
    } else {
        h0_score = 1;
        h1_score = 0;
    }

    float4 clamped_history0 = history0;
    float4 clamped_history1 = history1;

#if 0
    clamped_history0.rgb = clamp(history0.rgb, nmin.rgb, nmax.rgb);
    clamped_history1.rgb = clamp(history1.rgb, nmin.rgb, nmax.rgb);
#else
    clamped_history0.rgb = soft_color_clamp(center.rgb, history0.rgb, ex.rgb, dev.rgb * n_deviations);
    clamped_history1.rgb = soft_color_clamp(center.rgb, history1.rgb, ex.rgb, dev.rgb * n_deviations);
#endif

    //float4 clamped_history = clamp(history0 * h0_score + history1 * h1_score, nmin, nmax);
    float4 clamped_history = clamped_history0 * h0_score + clamped_history1 * h1_score;

    #if !USE_NEIGHBORHOOD_CLAMP
        clamped_history = history0 * h0_score + history1 * h1_score;
    #endif

    //float sample_count = history0.w * h0_score + history1.w * h1_score;
    //sample_count *= reproj.z;

    //clamped_history = lerp(center, clamped_history, reproj.z);
    //clamped_history = center;

    //clamped_history = history0;
    //clamped_history.w = history0.w;

    float max_sample_count = 16;
    float current_sample_count = clamped_history.a;

    float4 filtered_center = center;
    float4 res = lerp(clamped_history, filtered_center, 1.0 / (1.0 + min(max_sample_count, current_sample_count)));
    res.w = min(current_sample_count, max_sample_count) + 1;
    //res.w = sample_count + 1;
    //res.w = refl_ray_length * 20;
    //res.w = (dev / ex).x * 16;
    //res.w = 2 * exp2(-20 * (dev / ex).x);
    //res.w = refl_ray_length;

    //res.rgb = working_to_linear(dev).rgb / max(1e-8, working_to_linear(ex).rgb);
    res = working_to_linear(res);
    
    output_tex[px] = max(0.0.xxxx, res);
}
