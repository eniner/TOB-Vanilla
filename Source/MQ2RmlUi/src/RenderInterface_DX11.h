#pragma once

#include <RmlUi/Core/RenderInterface.h>
#include <RmlUi/Core/Types.h>
#include <d3d11.h>
#include <cstdint>
#include <vector>

// Direct3D 11 backend for RmlUi 6 (core path: geometry, textures, scissor, stencil clip, transforms).
// Gradients / layers / filters are stubbed (caps bit 0) until a full shader suite is ported from
// RmlUi's official DX11 backend. Matches the host model: draw into a host-bound RTV+DSV.
class RenderInterface_DX11 : public Rml::RenderInterface
{
public:
	void SetDevice(ID3D11Device* device);
	ID3D11Device* GetDevice() const { return m_device; }
	ID3D11DeviceContext* GetContext() const { return m_context; }

	// Sets up pipeline state for drawing into the currently bound render target of the given size.
	// Bound depth-stencil must have a stencil channel (DXGI_FORMAT_D24_UNORM_S8_UINT).
	void BeginFrame(int width, int height);
	void EndFrame();

	// Releases device-owned resources; call on InvalidateDeviceObjects.
	void OnLostDevice();

	enum RenderCaps : unsigned
	{
		CapGradients = 1u << 0,
		CapFilters = 1u << 1,
		CapLayers = 1u << 2,
		CapBoxShadow = 1u << 3,
		CapBackdrop = 1u << 4,
		CapMask = 1u << 5,
	};
	unsigned GetRenderCaps();

	Rml::CompiledGeometryHandle CompileGeometry(Rml::Span<const Rml::Vertex> vertices, Rml::Span<const int> indices) override;
	void RenderGeometry(Rml::CompiledGeometryHandle geometry, Rml::Vector2f translation, Rml::TextureHandle texture) override;
	void ReleaseGeometry(Rml::CompiledGeometryHandle geometry) override;

	Rml::TextureHandle LoadTexture(Rml::Vector2i& texture_dimensions, const Rml::String& source) override;
	Rml::TextureHandle GenerateTexture(Rml::Span<const Rml::byte> source, Rml::Vector2i source_dimensions) override;
	void ReleaseTexture(Rml::TextureHandle texture) override;

	void EnableScissorRegion(bool enable) override;
	void SetScissorRegion(Rml::Rectanglei region) override;

	void EnableClipMask(bool enable) override;
	void RenderToClipMask(Rml::ClipMaskOperation operation, Rml::CompiledGeometryHandle geometry, Rml::Vector2f translation) override;

	void SetTransform(const Rml::Matrix4f* transform) override;

	Rml::CompiledShaderHandle CompileShader(const Rml::String& name, const Rml::Dictionary& parameters) override;
	void RenderShader(Rml::CompiledShaderHandle shader, Rml::CompiledGeometryHandle geometry, Rml::Vector2f translation,
		Rml::TextureHandle texture) override;
	void ReleaseShader(Rml::CompiledShaderHandle shader) override;

	Rml::LayerHandle PushLayer() override;
	void CompositeLayers(Rml::LayerHandle source, Rml::LayerHandle destination, Rml::BlendMode blend_mode,
		Rml::Span<const Rml::CompiledFilterHandle> filters) override;
	void PopLayer() override;
	Rml::TextureHandle SaveLayerAsTexture() override;
	Rml::CompiledFilterHandle SaveLayerAsMaskImage() override;
	Rml::CompiledFilterHandle CompileFilter(const Rml::String& name, const Rml::Dictionary& parameters) override;
	void ReleaseFilter(Rml::CompiledFilterHandle filter) override;

private:
	struct Vertex
	{
		float x, y, z;
		uint32_t color; // ABGR for DXGI_FORMAT_R8G8B8A8_UNORM shader (we pack as RGBA bytes)
		float u, v;
	};

	struct Geometry
	{
		ID3D11Buffer* vb = nullptr;
		ID3D11Buffer* ib = nullptr;
		UINT indexCount = 0;
		DXGI_FORMAT indexFormat = DXGI_FORMAT_R16_UINT;
	};

	struct Texture
	{
		ID3D11Texture2D* tex = nullptr;
		ID3D11ShaderResourceView* srv = nullptr;
	};

	struct Constants
	{
		float transform[16];
		float translation[2];
		float pad[2];
	};

	bool EnsurePipeline();
	void ReleasePipeline();
	Texture* CreateTextureRGBA(const uint8_t* rgba, int width, int height, bool premultiply);
	void DrawGeometry(Geometry* geometry, Texture* texture, Rml::Vector2f translation, bool writeColor);

	ID3D11Device* m_device = nullptr;
	ID3D11DeviceContext* m_context = nullptr;

	ID3D11VertexShader* m_vs = nullptr;
	ID3D11PixelShader* m_psTex = nullptr;
	ID3D11PixelShader* m_psColor = nullptr;
	ID3D11InputLayout* m_layout = nullptr;
	ID3D11Buffer* m_cb = nullptr;
	ID3D11SamplerState* m_sampler = nullptr;
	ID3D11BlendState* m_blendPremul = nullptr;
	ID3D11BlendState* m_blendDisableColor = nullptr;
	ID3D11RasterizerState* m_rsScissorOn = nullptr;
	ID3D11RasterizerState* m_rsScissorOff = nullptr;
	ID3D11DepthStencilState* m_dssDisabled = nullptr;
	ID3D11DepthStencilState* m_dssStencilSet = nullptr;       // Set / SetInverse (REPLACE)
	ID3D11DepthStencilState* m_dssStencilIntersect = nullptr; // Intersect (INCR)
	ID3D11DepthStencilState* m_dssStencilTest = nullptr;      // EQUAL test while drawing

	bool m_inFrame = false;
	int m_width = 0;
	int m_height = 0;
	bool m_scissorEnabled = false;
	D3D11_RECT m_scissorRect = {};
	bool m_clipEnabled = false;
	UINT m_stencilRef = 0;
	// Bound by the host for this frame; kept so stencil clears/writes always hit a real DSV.
	ID3D11RenderTargetView* m_frameRtv = nullptr;
	ID3D11DepthStencilView* m_frameDsv = nullptr;
	Rml::Matrix4f m_projection = Rml::Matrix4f::Identity();
	Rml::Matrix4f m_transform = Rml::Matrix4f::Identity(); // projection * (optional user transform)
};
