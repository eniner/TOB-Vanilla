#include "RenderInterface_DX11.h"
#include "EqIconAtlas.h"

#include <RmlUi/Core/Core.h>
#include <RmlUi/Core/FileInterface.h>
#include <RmlUi/Core/Log.h>
#include <RmlUi/Core/Math.h>

#define STB_IMAGE_IMPLEMENTATION
#define STBI_NO_STDIO
#define STBI_ONLY_PNG
#define STBI_ONLY_JPEG
#define STBI_ONLY_TGA
#define STBI_ONLY_BMP
#include "stb_image.h"

#include <d3dcompiler.h>

#include <cstring>
#include <string>
#include <vector>

namespace {

const char* kShaderSrc = R"(
cbuffer Constants : register(b0)
{
	float4x4 Transform;
	float2 Translation;
	float2 Pad;
};

struct VSIn
{
	float3 pos : POSITION;
	float4 col : COLOR0;
	float2 uv  : TEXCOORD0;
};

struct PSIn
{
	float4 pos : SV_POSITION;
	float4 col : COLOR0;
	float2 uv  : TEXCOORD0;
};

PSIn VSMain(VSIn vin)
{
	PSIn o;
	// Column-vector: mul(M, v). Matches RmlUi's official DX11 backend.
	float4 p = float4(vin.pos.xy + Translation, 0.0, 1.0);
	o.pos = mul(Transform, p);
	o.col = vin.col;
	o.uv = vin.uv;
	return o;
}

Texture2D tex0 : register(t0);
SamplerState samp0 : register(s0);

float4 PSTex(PSIn pin) : SV_Target
{
	return pin.col * tex0.Sample(samp0, pin.uv);
}

float4 PSColor(PSIn pin) : SV_Target
{
	return pin.col;
}
)";

uint32_t PackColor(const Rml::ColourbPremultiplied& c)
{
	// DXGI R8G8B8A8_UNORM in little-endian vertex color: R,G,B,A bytes.
	return (uint32_t)c.red | ((uint32_t)c.green << 8) | ((uint32_t)c.blue << 16) | ((uint32_t)c.alpha << 24);
}

} // namespace

void RenderInterface_DX11::SetDevice(ID3D11Device* device)
{
	if (m_device == device)
		return;
	OnLostDevice();
	m_device = device;
	m_context = nullptr;
	if (m_device)
		m_device->GetImmediateContext(&m_context);
}

void RenderInterface_DX11::OnLostDevice()
{
	ReleasePipeline();
	if (m_frameRtv) { m_frameRtv->Release(); m_frameRtv = nullptr; }
	if (m_frameDsv) { m_frameDsv->Release(); m_frameDsv = nullptr; }
	if (m_context)
	{
		m_context->Release();
		m_context = nullptr;
	}
	m_device = nullptr;
	m_inFrame = false;
}

void RenderInterface_DX11::ReleasePipeline()
{
	auto rel = [](auto*& p) { if (p) { p->Release(); p = nullptr; } };
	rel(m_vs); rel(m_psTex); rel(m_psColor); rel(m_layout); rel(m_cb); rel(m_sampler);
	rel(m_blendPremul); rel(m_blendDisableColor);
	rel(m_rsScissorOn); rel(m_rsScissorOff);
	rel(m_dssDisabled); rel(m_dssStencilSet); rel(m_dssStencilIntersect); rel(m_dssStencilTest);
}

bool RenderInterface_DX11::EnsurePipeline()
{
	if (m_vs)
		return true;
	if (!m_device)
		return false;

	ID3DBlob* vsBlob = nullptr;
	ID3DBlob* err = nullptr;
	HRESULT hr = D3DCompile(kShaderSrc, strlen(kShaderSrc), "rml_dx11", nullptr, nullptr, "VSMain", "vs_4_0", 0, 0, &vsBlob, &err);
	if (FAILED(hr))
	{
		if (err) { Rml::Log::Message(Rml::Log::LT_ERROR, "DX11 VS: %s", (char*)err->GetBufferPointer()); err->Release(); }
		return false;
	}
	hr = m_device->CreateVertexShader(vsBlob->GetBufferPointer(), vsBlob->GetBufferSize(), nullptr, &m_vs);
	if (FAILED(hr))
	{
		vsBlob->Release();
		return false;
	}

	D3D11_INPUT_ELEMENT_DESC layout[] = {
		{ "POSITION", 0, DXGI_FORMAT_R32G32B32_FLOAT, 0, 0, D3D11_INPUT_PER_VERTEX_DATA, 0 },
		{ "COLOR", 0, DXGI_FORMAT_R8G8B8A8_UNORM, 0, 12, D3D11_INPUT_PER_VERTEX_DATA, 0 },
		{ "TEXCOORD", 0, DXGI_FORMAT_R32G32_FLOAT, 0, 16, D3D11_INPUT_PER_VERTEX_DATA, 0 },
	};
	hr = m_device->CreateInputLayout(layout, 3, vsBlob->GetBufferPointer(), vsBlob->GetBufferSize(), &m_layout);
	vsBlob->Release();
	if (FAILED(hr))
		return false;

	ID3DBlob* psBlob = nullptr;
	hr = D3DCompile(kShaderSrc, strlen(kShaderSrc), "rml_dx11", nullptr, nullptr, "PSTex", "ps_4_0", 0, 0, &psBlob, &err);
	if (FAILED(hr))
	{
		if (err) { err->Release(); }
		return false;
	}
	m_device->CreatePixelShader(psBlob->GetBufferPointer(), psBlob->GetBufferSize(), nullptr, &m_psTex);
	psBlob->Release();

	hr = D3DCompile(kShaderSrc, strlen(kShaderSrc), "rml_dx11", nullptr, nullptr, "PSColor", "ps_4_0", 0, 0, &psBlob, &err);
	if (FAILED(hr))
	{
		if (err) { err->Release(); }
		return false;
	}
	m_device->CreatePixelShader(psBlob->GetBufferPointer(), psBlob->GetBufferSize(), nullptr, &m_psColor);
	psBlob->Release();

	D3D11_BUFFER_DESC cbd = {};
	cbd.ByteWidth = sizeof(Constants);
	cbd.Usage = D3D11_USAGE_DYNAMIC;
	cbd.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
	cbd.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
	if (FAILED(m_device->CreateBuffer(&cbd, nullptr, &m_cb)))
		return false;

	D3D11_SAMPLER_DESC sd = {};
	sd.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
	sd.AddressU = sd.AddressV = sd.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
	sd.ComparisonFunc = D3D11_COMPARISON_ALWAYS;
	sd.MaxLOD = D3D11_FLOAT32_MAX;
	m_device->CreateSamplerState(&sd, &m_sampler);

	D3D11_BLEND_DESC bd = {};
	bd.RenderTarget[0].BlendEnable = TRUE;
	bd.RenderTarget[0].SrcBlend = D3D11_BLEND_ONE;
	bd.RenderTarget[0].DestBlend = D3D11_BLEND_INV_SRC_ALPHA;
	bd.RenderTarget[0].BlendOp = D3D11_BLEND_OP_ADD;
	bd.RenderTarget[0].SrcBlendAlpha = D3D11_BLEND_ONE;
	bd.RenderTarget[0].DestBlendAlpha = D3D11_BLEND_INV_SRC_ALPHA;
	bd.RenderTarget[0].BlendOpAlpha = D3D11_BLEND_OP_ADD;
	bd.RenderTarget[0].RenderTargetWriteMask = D3D11_COLOR_WRITE_ENABLE_ALL;
	m_device->CreateBlendState(&bd, &m_blendPremul);

	bd.RenderTarget[0].RenderTargetWriteMask = 0;
	m_device->CreateBlendState(&bd, &m_blendDisableColor);

	// DepthClipEnable MUST be false: perspective / rotateY (Fan, Flip, carousel) push
	// vertices outside [0,w] in z; hardware z-clip then slices cards. Matches official DX11.
	D3D11_RASTERIZER_DESC rd = {};
	rd.FillMode = D3D11_FILL_SOLID;
	rd.CullMode = D3D11_CULL_NONE;
	rd.DepthClipEnable = FALSE;
	rd.ScissorEnable = FALSE;
	m_device->CreateRasterizerState(&rd, &m_rsScissorOff);
	rd.ScissorEnable = TRUE;
	m_device->CreateRasterizerState(&rd, &m_rsScissorOn);

	// Stencil states. Clip-off uses StencilEnable=FALSE (matches working DX9 path).
	D3D11_DEPTH_STENCIL_DESC dsd = {};
	dsd.DepthEnable = FALSE;
	dsd.DepthWriteMask = D3D11_DEPTH_WRITE_MASK_ZERO;
	dsd.StencilEnable = FALSE;
	dsd.StencilReadMask = 0xFF;
	dsd.StencilWriteMask = 0xFF;
	dsd.FrontFace.StencilFunc = D3D11_COMPARISON_ALWAYS;
	dsd.FrontFace.StencilPassOp = D3D11_STENCIL_OP_KEEP;
	dsd.FrontFace.StencilFailOp = D3D11_STENCIL_OP_KEEP;
	dsd.FrontFace.StencilDepthFailOp = D3D11_STENCIL_OP_KEEP;
	dsd.BackFace = dsd.FrontFace;
	if (FAILED(m_device->CreateDepthStencilState(&dsd, &m_dssDisabled)))
		return false;

	dsd.StencilEnable = TRUE;
	dsd.FrontFace.StencilPassOp = D3D11_STENCIL_OP_REPLACE;
	dsd.BackFace = dsd.FrontFace;
	if (FAILED(m_device->CreateDepthStencilState(&dsd, &m_dssStencilSet)))
		return false;

	// INCRSAT matches the working DX9 backend (nested border-radius clips).
	dsd.FrontFace.StencilPassOp = D3D11_STENCIL_OP_INCR_SAT;
	dsd.BackFace = dsd.FrontFace;
	if (FAILED(m_device->CreateDepthStencilState(&dsd, &m_dssStencilIntersect)))
		return false;

	dsd.StencilWriteMask = 0;
	dsd.FrontFace.StencilFunc = D3D11_COMPARISON_EQUAL;
	dsd.FrontFace.StencilPassOp = D3D11_STENCIL_OP_KEEP;
	dsd.BackFace = dsd.FrontFace;
	if (FAILED(m_device->CreateDepthStencilState(&dsd, &m_dssStencilTest)))
		return false;

	return m_vs && m_psTex && m_psColor && m_layout && m_cb
		&& m_dssDisabled && m_dssStencilSet && m_dssStencilIntersect && m_dssStencilTest;
}

unsigned RenderInterface_DX11::GetRenderCaps()
{
	// Core path only for this port (gradients/layers/filters not yet ported).
	return 0;
}

void RenderInterface_DX11::BeginFrame(int width, int height)
{
	m_width = width;
	m_height = height;
	m_inFrame = m_device && m_context && EnsurePipeline();
	if (!m_inFrame)
		return;

	// Keep our own refs to the host-bound RTV/DSV for the whole frame. Stencil clip
	// masks require a live DSV; OMGet alone during nested draws has been flaky.
	if (m_frameRtv) { m_frameRtv->Release(); m_frameRtv = nullptr; }
	if (m_frameDsv) { m_frameDsv->Release(); m_frameDsv = nullptr; }
	m_context->OMGetRenderTargets(1, &m_frameRtv, &m_frameDsv);
	if (m_frameRtv || m_frameDsv)
		m_context->OMSetRenderTargets(1, &m_frameRtv, m_frameDsv);

	D3D11_VIEWPORT vp = {};
	vp.Width = (float)width;
	vp.Height = (float)height;
	vp.MaxDepth = 1.0f;
	m_context->RSSetViewports(1, &vp);

	m_context->IASetInputLayout(m_layout);
	m_context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
	m_context->VSSetShader(m_vs, nullptr, 0);
	m_context->VSSetConstantBuffers(0, 1, &m_cb);
	m_context->PSSetSamplers(0, 1, &m_sampler);
	const float blendFactor[4] = { 0, 0, 0, 0 };
	m_context->OMSetBlendState(m_blendPremul, blendFactor, 0xFFFFFFFF);

	m_projection = Rml::Matrix4f::ProjectOrtho(0.f, (float)width, (float)height, 0.f, -10000.f, 10000.f);
	m_transform = m_projection;
	m_stencilRef = 0;
	m_scissorEnabled = false;
	m_scissorRect = { 0, 0, width, height };
	m_clipEnabled = false;

	m_context->RSSetState(m_rsScissorOff);
	m_context->OMSetDepthStencilState(m_dssDisabled, 0);

	const FLOAT clearColor[4] = { 0, 0, 0, 0 };
	if (m_frameRtv)
		m_context->ClearRenderTargetView(m_frameRtv, clearColor);
	if (m_frameDsv)
		m_context->ClearDepthStencilView(m_frameDsv, D3D11_CLEAR_STENCIL, 1.0f, 0);
}

void RenderInterface_DX11::EndFrame()
{
	m_inFrame = false;
	if (m_frameRtv) { m_frameRtv->Release(); m_frameRtv = nullptr; }
	if (m_frameDsv) { m_frameDsv->Release(); m_frameDsv = nullptr; }
}

Rml::CompiledGeometryHandle RenderInterface_DX11::CompileGeometry(Rml::Span<const Rml::Vertex> vertices, Rml::Span<const int> indices)
{
	if (!m_device || vertices.empty() || indices.empty())
		return 0;

	auto* g = new Geometry();
	std::vector<Vertex> verts(vertices.size());
	for (size_t i = 0; i < vertices.size(); ++i)
	{
		verts[i].x = vertices[i].position.x;
		verts[i].y = vertices[i].position.y;
		verts[i].z = 0.f;
		verts[i].color = PackColor(vertices[i].colour);
		verts[i].u = vertices[i].tex_coord.x;
		verts[i].v = vertices[i].tex_coord.y;
	}

	D3D11_BUFFER_DESC bd = {};
	bd.Usage = D3D11_USAGE_IMMUTABLE;
	bd.ByteWidth = (UINT)(verts.size() * sizeof(Vertex));
	bd.BindFlags = D3D11_BIND_VERTEX_BUFFER;
	D3D11_SUBRESOURCE_DATA sd = { verts.data(), 0, 0 };
	if (FAILED(m_device->CreateBuffer(&bd, &sd, &g->vb)))
	{
		delete g;
		return 0;
	}

	g->indexCount = (UINT)indices.size();
	if (vertices.size() <= 0xFFFF)
	{
		std::vector<uint16_t> idx(indices.size());
		for (size_t i = 0; i < indices.size(); ++i)
			idx[i] = (uint16_t)indices[i];
		g->indexFormat = DXGI_FORMAT_R16_UINT;
		bd.ByteWidth = (UINT)(idx.size() * sizeof(uint16_t));
		bd.BindFlags = D3D11_BIND_INDEX_BUFFER;
		sd.pSysMem = idx.data();
		if (FAILED(m_device->CreateBuffer(&bd, &sd, &g->ib)))
		{
			g->vb->Release();
			delete g;
			return 0;
		}
	}
	else
	{
		std::vector<uint32_t> idx(indices.begin(), indices.end());
		g->indexFormat = DXGI_FORMAT_R32_UINT;
		bd.ByteWidth = (UINT)(idx.size() * sizeof(uint32_t));
		bd.BindFlags = D3D11_BIND_INDEX_BUFFER;
		sd.pSysMem = idx.data();
		if (FAILED(m_device->CreateBuffer(&bd, &sd, &g->ib)))
		{
			g->vb->Release();
			delete g;
			return 0;
		}
	}

	return reinterpret_cast<Rml::CompiledGeometryHandle>(g);
}

void RenderInterface_DX11::ReleaseGeometry(Rml::CompiledGeometryHandle handle)
{
	auto* g = reinterpret_cast<Geometry*>(handle);
	if (!g)
		return;
	if (g->vb) g->vb->Release();
	if (g->ib) g->ib->Release();
	delete g;
}

void RenderInterface_DX11::DrawGeometry(Geometry* geometry, Texture* texture, Rml::Vector2f translation, bool writeColor)
{
	if (!m_inFrame || !geometry)
		return;

	Constants c = {};
	std::memcpy(c.transform, m_transform.data(), sizeof(float) * 16);
	c.translation[0] = translation.x;
	c.translation[1] = translation.y;

	D3D11_MAPPED_SUBRESOURCE mapped = {};
	if (SUCCEEDED(m_context->Map(m_cb, 0, D3D11_MAP_WRITE_DISCARD, 0, &mapped)))
	{
		std::memcpy(mapped.pData, &c, sizeof(c));
		m_context->Unmap(m_cb, 0);
	}

	UINT stride = sizeof(Vertex), offset = 0;
	m_context->IASetVertexBuffers(0, 1, &geometry->vb, &stride, &offset);
	m_context->IASetIndexBuffer(geometry->ib, geometry->indexFormat, 0);

	const float blendFactor[4] = { 0, 0, 0, 0 };
	m_context->OMSetBlendState(writeColor ? m_blendPremul : m_blendDisableColor, blendFactor, 0xFFFFFFFF);
	m_context->RSSetState(m_scissorEnabled ? m_rsScissorOn : m_rsScissorOff);
	if (m_scissorEnabled)
		m_context->RSSetScissorRects(1, &m_scissorRect);
	// Color draws: stencil-test when a clip mask is active. Mask writes set DSS in RenderToClipMask.
	if (writeColor)
		m_context->OMSetDepthStencilState(m_clipEnabled ? m_dssStencilTest : m_dssDisabled, m_stencilRef);

	// Keep input layout / topology / VS bound (ImGui or other plugins may have changed them).
	m_context->IASetInputLayout(m_layout);
	m_context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
	m_context->VSSetShader(m_vs, nullptr, 0);
	m_context->VSSetConstantBuffers(0, 1, &m_cb);

	if (texture && texture->srv)
	{
		m_context->PSSetShader(m_psTex, nullptr, 0);
		m_context->PSSetShaderResources(0, 1, &texture->srv);
		m_context->PSSetSamplers(0, 1, &m_sampler);
	}
	else
	{
		m_context->PSSetShader(m_psColor, nullptr, 0);
		ID3D11ShaderResourceView* nullSrv = nullptr;
		m_context->PSSetShaderResources(0, 1, &nullSrv);
	}

	m_context->DrawIndexed(geometry->indexCount, 0, 0);
}

void RenderInterface_DX11::RenderGeometry(Rml::CompiledGeometryHandle handle, Rml::Vector2f translation, Rml::TextureHandle texture)
{
	DrawGeometry(reinterpret_cast<Geometry*>(handle), reinterpret_cast<Texture*>(texture), translation, true);
}

RenderInterface_DX11::Texture* RenderInterface_DX11::CreateTextureRGBA(const uint8_t* rgba, int width, int height, bool premultiply)
{
	if (!m_device || width <= 0 || height <= 0 || !rgba)
		return nullptr;

	std::vector<uint8_t> pixels((size_t)width * height * 4);
	for (int i = 0; i < width * height; ++i)
	{
		const uint8_t* s = rgba + i * 4;
		uint8_t* d = pixels.data() + i * 4;
		const uint8_t a = s[3];
		if (premultiply)
		{
			d[0] = (uint8_t)((s[0] * a + 127) / 255);
			d[1] = (uint8_t)((s[1] * a + 127) / 255);
			d[2] = (uint8_t)((s[2] * a + 127) / 255);
		}
		else
		{
			d[0] = s[0];
			d[1] = s[1];
			d[2] = s[2];
		}
		d[3] = a;
	}

	D3D11_TEXTURE2D_DESC td = {};
	td.Width = width;
	td.Height = height;
	td.MipLevels = 1;
	td.ArraySize = 1;
	td.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
	td.SampleDesc.Count = 1;
	td.Usage = D3D11_USAGE_DEFAULT;
	td.BindFlags = D3D11_BIND_SHADER_RESOURCE;

	D3D11_SUBRESOURCE_DATA sd = {};
	sd.pSysMem = pixels.data();
	sd.SysMemPitch = width * 4;

	auto* t = new Texture();
	if (FAILED(m_device->CreateTexture2D(&td, &sd, &t->tex)))
	{
		delete t;
		return nullptr;
	}
	if (FAILED(m_device->CreateShaderResourceView(t->tex, nullptr, &t->srv)))
	{
		t->tex->Release();
		delete t;
		return nullptr;
	}
	return t;
}

Rml::TextureHandle RenderInterface_DX11::LoadTexture(Rml::Vector2i& texture_dimensions, const Rml::String& source)
{
	{
		std::string kind;
		int id = 0;
		if (EqIcon::ParseEqUrl(source.c_str(), kind, id))
		{
			std::vector<uint8_t> rgba;
			int w = 0, h = 0;
			if (!EqIcon::Sample(kind.c_str(), id, rgba, w, h))
			{
				Rml::Log::Message(Rml::Log::LT_WARNING, "EQ icon sample failed for '%s'", source.c_str());
				return 0;
			}
			Texture* texture = CreateTextureRGBA(rgba.data(), w, h, true);
			if (!texture)
				return 0;
			texture_dimensions = { w, h };
			return reinterpret_cast<Rml::TextureHandle>(texture);
		}
	}

	Rml::FileInterface* files = Rml::GetFileInterface();
	Rml::FileHandle file = files->Open(source);
	if (!file)
	{
		Rml::Log::Message(Rml::Log::LT_WARNING, "Could not open image '%s'", source.c_str());
		return 0;
	}
	const size_t size = files->Length(file);
	std::vector<stbi_uc> bytes(size);
	files->Read(bytes.data(), size, file);
	files->Close(file);

	int width = 0, height = 0, channels = 0;
	stbi_uc* pixels = stbi_load_from_memory(bytes.data(), (int)bytes.size(), &width, &height, &channels, 4);
	if (!pixels)
	{
		Rml::Log::Message(Rml::Log::LT_WARNING, "Could not decode image '%s': %s", source.c_str(), stbi_failure_reason());
		return 0;
	}
	Texture* texture = CreateTextureRGBA(pixels, width, height, true);
	stbi_image_free(pixels);
	if (!texture)
		return 0;
	texture_dimensions = { width, height };
	return reinterpret_cast<Rml::TextureHandle>(texture);
}

Rml::TextureHandle RenderInterface_DX11::GenerateTexture(Rml::Span<const Rml::byte> source, Rml::Vector2i dimensions)
{
	Texture* texture = CreateTextureRGBA(source.data(), dimensions.x, dimensions.y, false);
	return reinterpret_cast<Rml::TextureHandle>(texture);
}

void RenderInterface_DX11::ReleaseTexture(Rml::TextureHandle handle)
{
	auto* t = reinterpret_cast<Texture*>(handle);
	if (!t)
		return;
	if (t->srv) t->srv->Release();
	if (t->tex) t->tex->Release();
	delete t;
}

void RenderInterface_DX11::EnableScissorRegion(bool enable)
{
	// Match working DX9: toggle scissor test. Re-apply last rect on enable so a
	// lone Enable(true) after Enable(false) still clips (RmlUi usually pairs with
	// SetScissorRegion, but this matches the proven MQ2RmlUi DX9 behavior).
	m_scissorEnabled = enable;
	if (!m_inFrame)
		return;
	if (enable)
	{
		m_context->RSSetState(m_rsScissorOn);
		m_context->RSSetScissorRects(1, &m_scissorRect);
	}
	else
	{
		m_context->RSSetState(m_rsScissorOff);
	}
}

void RenderInterface_DX11::SetScissorRegion(Rml::Rectanglei region)
{
	if (!m_inFrame)
		return;

	const bool valid = region.Valid() && region.Width() > 0 && region.Height() > 0;
	if (!valid)
	{
		m_scissorEnabled = false;
		m_context->RSSetState(m_rsScissorOff);
		return;
	}

	m_scissorEnabled = true;
	m_scissorRect.left = Rml::Math::Clamp(region.Left(), 0, m_width);
	m_scissorRect.top = Rml::Math::Clamp(region.Top(), 0, m_height);
	m_scissorRect.right = Rml::Math::Clamp(region.Right(), 0, m_width);
	m_scissorRect.bottom = Rml::Math::Clamp(region.Bottom(), 0, m_height);
	m_context->RSSetState(m_rsScissorOn);
	m_context->RSSetScissorRects(1, &m_scissorRect);
}

void RenderInterface_DX11::EnableClipMask(bool enable)
{
	m_clipEnabled = enable;
	if (!m_inFrame)
		return;
	// DX9: STENCILENABLE on/off. When enabling before RenderToClipMask has written,
	// EQUAL with ref 0 against a cleared-0 buffer still passes (harmless).
	m_context->OMSetDepthStencilState(enable ? m_dssStencilTest : m_dssDisabled, m_stencilRef);
}

void RenderInterface_DX11::RenderToClipMask(Rml::ClipMaskOperation operation, Rml::CompiledGeometryHandle geometry, Rml::Vector2f translation)
{
	// Match the working MQ2RmlUi DX9 clip-mask path (SetInverse clear/write/test).
	if (!m_inFrame || !geometry || !m_frameDsv)
		return;

	// Ensure RTV+DSV stay bound for stencil writes.
	m_context->OMSetRenderTargets(1, &m_frameRtv, m_frameDsv);

	UINT writeRef = 1;
	UINT testValue = m_stencilRef;
	ID3D11DepthStencilState* writeState = m_dssStencilSet;
	UINT clearStencilValue = 0;

	switch (operation)
	{
	case Rml::ClipMaskOperation::Set:
		writeRef = 1;
		testValue = 1;
		writeState = m_dssStencilSet;
		clearStencilValue = 0;
		break;
	case Rml::ClipMaskOperation::SetInverse:
		// Clear to 1, write 0 on geometry, test EQUAL 1 (outside). Same as DX9/GL3.
		writeRef = 0;
		testValue = 1;
		writeState = m_dssStencilSet;
		clearStencilValue = 1;
		break;
	case Rml::ClipMaskOperation::Intersect:
		writeRef = 1; // unused by INCR_SAT
		testValue = m_stencilRef + 1;
		writeState = m_dssStencilIntersect;
		break;
	}

	const bool clearStencil = (operation == Rml::ClipMaskOperation::Set || operation == Rml::ClipMaskOperation::SetInverse);
	if (clearStencil)
		m_context->ClearDepthStencilView(m_frameDsv, D3D11_CLEAR_STENCIL, 1.0f, clearStencilValue);

	const float blendFactor[4] = { 0, 0, 0, 0 };
	m_context->OMSetBlendState(m_blendDisableColor, blendFactor, 0xFFFFFFFF);
	m_context->OMSetDepthStencilState(writeState, writeRef);

	DrawGeometry(reinterpret_cast<Geometry*>(geometry), nullptr, translation, false);

	m_stencilRef = testValue;
	m_clipEnabled = true;
	m_context->OMSetBlendState(m_blendPremul, blendFactor, 0xFFFFFFFF);
	m_context->OMSetDepthStencilState(m_dssStencilTest, m_stencilRef);
}

void RenderInterface_DX11::SetTransform(const Rml::Matrix4f* transform)
{
	// Official DX11 backend: m_transform = projection * user (or projection alone).
	m_transform = transform ? (m_projection * (*transform)) : m_projection;
}

Rml::CompiledShaderHandle RenderInterface_DX11::CompileShader(const Rml::String&, const Rml::Dictionary&) { return 0; }
void RenderInterface_DX11::RenderShader(Rml::CompiledShaderHandle, Rml::CompiledGeometryHandle, Rml::Vector2f, Rml::TextureHandle) {}
void RenderInterface_DX11::ReleaseShader(Rml::CompiledShaderHandle) {}

Rml::LayerHandle RenderInterface_DX11::PushLayer() { return 0; }
void RenderInterface_DX11::CompositeLayers(Rml::LayerHandle, Rml::LayerHandle, Rml::BlendMode, Rml::Span<const Rml::CompiledFilterHandle>) {}
void RenderInterface_DX11::PopLayer() {}
Rml::TextureHandle RenderInterface_DX11::SaveLayerAsTexture() { return 0; }
Rml::CompiledFilterHandle RenderInterface_DX11::SaveLayerAsMaskImage() { return 0; }
Rml::CompiledFilterHandle RenderInterface_DX11::CompileFilter(const Rml::String&, const Rml::Dictionary&) { return 0; }
void RenderInterface_DX11::ReleaseFilter(Rml::CompiledFilterHandle) {}
