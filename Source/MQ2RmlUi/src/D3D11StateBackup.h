#pragma once
// Full D3D11 pipeline snapshot for code that draws inside EQ's frame (Stage 0, 2026-11-12).
// Captures every slot this plugin binds (IA VB 0..1 + IB + layout + topology; VS/PS shader, CB 0..1,
// SRV 0..1, sampler 0..1; GS/HS/DS shaders; RS state/viewports/scissors; OM blend/depth/all 8 RTVs + DSV)
// and puts back exactly what was there, so nothing we bound survives into EQ's rendering.
#include <d3d11.h>

struct D3D11StateBackup
{
	static constexpr UINT kVB = 2, kCB = 2, kSRV = 2, kSamp = 2;
	static constexpr UINT kRT = D3D11_SIMULTANEOUS_RENDER_TARGET_COUNT;

	UINT nvp = 0;
	D3D11_VIEWPORT vps[D3D11_VIEWPORT_AND_SCISSORRECT_OBJECT_COUNT_PER_PIPELINE]{};
	UINT nsc = 0;
	D3D11_RECT sc[D3D11_VIEWPORT_AND_SCISSORRECT_OBJECT_COUNT_PER_PIPELINE]{};
	ID3D11RasterizerState* rs = nullptr;
	ID3D11BlendState* blend = nullptr;
	FLOAT bf[4]{};
	UINT mask = 0;
	ID3D11DepthStencilState* dss = nullptr;
	UINT stencil = 0;
	ID3D11RenderTargetView* rtvs[kRT]{};
	ID3D11RenderTargetView* rtv = nullptr;   // = rtvs[0] (borrowed, not separately ref-counted)
	ID3D11DepthStencilView* dsv = nullptr;

	ID3D11Buffer* vb[kVB]{};
	UINT stride[kVB]{}, offset[kVB]{};
	ID3D11Buffer* ib = nullptr;
	DXGI_FORMAT ibFmt = DXGI_FORMAT_UNKNOWN;
	UINT ibOff = 0;
	ID3D11InputLayout* layout = nullptr;
	D3D11_PRIMITIVE_TOPOLOGY topo = D3D11_PRIMITIVE_TOPOLOGY_UNDEFINED;

	ID3D11VertexShader* vs = nullptr;
	ID3D11Buffer* vsCb[kCB]{};
	ID3D11ShaderResourceView* vsSrv[kSRV]{};
	ID3D11SamplerState* vsSamp[kSamp]{};
	ID3D11PixelShader* ps = nullptr;
	ID3D11Buffer* psCb[kCB]{};
	ID3D11ShaderResourceView* psSrv[kSRV]{};
	ID3D11SamplerState* psSamp[kSamp]{};
	ID3D11GeometryShader* gs = nullptr;
	ID3D11HullShader* hs = nullptr;
	ID3D11DomainShader* ds = nullptr;
	bool captured = false;

	void Capture(ID3D11DeviceContext* ctx)
	{
		nvp = D3D11_VIEWPORT_AND_SCISSORRECT_OBJECT_COUNT_PER_PIPELINE;
		ctx->RSGetViewports(&nvp, vps);
		nsc = D3D11_VIEWPORT_AND_SCISSORRECT_OBJECT_COUNT_PER_PIPELINE;
		ctx->RSGetScissorRects(&nsc, sc);
		ctx->RSGetState(&rs);
		ctx->OMGetBlendState(&blend, bf, &mask);
		ctx->OMGetDepthStencilState(&dss, &stencil);
		ctx->OMGetRenderTargets(kRT, rtvs, &dsv);
		rtv = rtvs[0];
		ctx->IAGetVertexBuffers(0, kVB, vb, stride, offset);
		ctx->IAGetIndexBuffer(&ib, &ibFmt, &ibOff);
		ctx->IAGetInputLayout(&layout);
		ctx->IAGetPrimitiveTopology(&topo);
		ctx->VSGetShader(&vs, nullptr, nullptr);
		ctx->VSGetConstantBuffers(0, kCB, vsCb);
		ctx->VSGetShaderResources(0, kSRV, vsSrv);
		ctx->VSGetSamplers(0, kSamp, vsSamp);
		ctx->PSGetShader(&ps, nullptr, nullptr);
		ctx->PSGetConstantBuffers(0, kCB, psCb);
		ctx->PSGetShaderResources(0, kSRV, psSrv);
		ctx->PSGetSamplers(0, kSamp, psSamp);
		ctx->GSGetShader(&gs, nullptr, nullptr);
		ctx->HSGetShader(&hs, nullptr, nullptr);
		ctx->DSGetShader(&ds, nullptr, nullptr);
		captured = true;
	}

	// Our draws are plain VS+PS: make sure a game-bound GS/HS/DS cannot intercept them.
	static void ClearExtraStages(ID3D11DeviceContext* ctx)
	{
		ctx->GSSetShader(nullptr, nullptr, 0);
		ctx->HSSetShader(nullptr, nullptr, 0);
		ctx->DSSetShader(nullptr, nullptr, 0);
	}

	void Restore(ID3D11DeviceContext* ctx)
	{
		if (!captured)
			return;
		captured = false;
		// Unbind our SRVs first so restoring an RTV that aliases one of them never trips the hazard tracker.
		ID3D11ShaderResourceView* noSrv[kSRV]{};
		ctx->PSSetShaderResources(0, kSRV, noSrv);
		ctx->VSSetShaderResources(0, kSRV, noSrv);
		ctx->OMSetRenderTargets(kRT, rtvs, dsv);
		ctx->RSSetViewports(nvp, vps);
		ctx->RSSetScissorRects(nsc, sc);
		ctx->RSSetState(rs);
		ctx->OMSetBlendState(blend, bf, mask);
		ctx->OMSetDepthStencilState(dss, stencil);
		ctx->IASetVertexBuffers(0, kVB, vb, stride, offset);
		ctx->IASetIndexBuffer(ib, ibFmt, ibOff);
		ctx->IASetInputLayout(layout);
		ctx->IASetPrimitiveTopology(topo);
		ctx->VSSetShader(vs, nullptr, 0);
		ctx->VSSetConstantBuffers(0, kCB, vsCb);
		ctx->VSSetShaderResources(0, kSRV, vsSrv);
		ctx->VSSetSamplers(0, kSamp, vsSamp);
		ctx->PSSetShader(ps, nullptr, 0);
		ctx->PSSetConstantBuffers(0, kCB, psCb);
		ctx->PSSetShaderResources(0, kSRV, psSrv);
		ctx->PSSetSamplers(0, kSamp, psSamp);
		ctx->GSSetShader(gs, nullptr, 0);
		ctx->HSSetShader(hs, nullptr, 0);
		ctx->DSSetShader(ds, nullptr, 0);

		auto rel = [](IUnknown* p) { if (p) p->Release(); };
		rel(rs); rel(blend); rel(dss); rel(dsv);
		for (auto* p : rtvs) rel(p);
		for (auto* p : vb) rel(p);
		rel(ib); rel(layout); rel(vs); rel(ps); rel(gs); rel(hs); rel(ds);
		for (auto* p : vsCb) rel(p);
		for (auto* p : vsSrv) rel(p);
		for (auto* p : vsSamp) rel(p);
		for (auto* p : psCb) rel(p);
		for (auto* p : psSrv) rel(p);
		for (auto* p : psSamp) rel(p);
		rs = nullptr; blend = nullptr; dss = nullptr; dsv = nullptr; rtv = nullptr;
		ib = nullptr; layout = nullptr; vs = nullptr; ps = nullptr; gs = nullptr; hs = nullptr; ds = nullptr;
		for (auto& p : rtvs) p = nullptr;
		for (auto& p : vb) p = nullptr;
		for (auto& p : vsCb) p = nullptr;
		for (auto& p : vsSrv) p = nullptr;
		for (auto& p : vsSamp) p = nullptr;
		for (auto& p : psCb) p = nullptr;
		for (auto& p : psSrv) p = nullptr;
		for (auto& p : psSamp) p = nullptr;
	}

	~D3D11StateBackup()
	{
		// Safety net: if a caller returns without Restore, still drop the references (no leak).
		if (!captured)
			return;
		auto rel = [](IUnknown* p) { if (p) p->Release(); };
		rel(rs); rel(blend); rel(dss); rel(dsv);
		for (auto* p : rtvs) rel(p);
		for (auto* p : vb) rel(p);
		rel(ib); rel(layout); rel(vs); rel(ps); rel(gs); rel(hs); rel(ds);
		for (auto* p : vsCb) rel(p);
		for (auto* p : vsSrv) rel(p);
		for (auto* p : vsSamp) rel(p);
		for (auto* p : psCb) rel(p);
		for (auto* p : psSrv) rel(p);
		for (auto* p : psSamp) rel(p);
	}
};
