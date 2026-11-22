// Lightweight skeleton placeholders shown while real data loads.
// Pure presentational — animation lives in styles.css (.skeleton).

export function SkeletonLine({ width = '100%', height = 14 }: { width?: string; height?: number }) {
  return <span className="skeleton" style={{ display: 'block', width, height, borderRadius: 6 }} />;
}

export function SkeletonGateRow() {
  return (
    <div className="skeleton-row" aria-hidden="true">
      <span className="skeleton" style={{ width: 42, height: 42, borderRadius: 10, flexShrink: 0 }} />
      <div style={{ flex: 1, display: 'grid', gap: 8 }}>
        <SkeletonLine width="45%" />
        <SkeletonLine width="70%" height={11} />
      </div>
      <span className="skeleton" style={{ width: 90, height: 28, borderRadius: 7 }} />
    </div>
  );
}

export function SkeletonList({ rows = 4 }: { rows?: number }) {
  return (
    <div role="status" aria-label="Cargando">
      {Array.from({ length: rows }, (_, i) => <SkeletonGateRow key={i} />)}
    </div>
  );
}
