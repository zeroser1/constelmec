import { Component, type ErrorInfo, type ReactNode } from 'react';
import { AlertTriangle } from 'lucide-react';

type Props = { children: ReactNode };
type State = { error: Error | null };

// Catches render-time crashes anywhere in the tree so a single broken view
// shows a recoverable message instead of a blank white screen.
export default class ErrorBoundary extends Component<Props, State> {
  state: State = { error: null };

  static getDerivedStateFromError(error: Error): State {
    return { error };
  }

  componentDidCatch(error: Error, info: ErrorInfo) {
    console.error('Constelmec render error:', error, info.componentStack);
  }

  render() {
    if (this.state.error) {
      return (
        <div className="boundary" role="alert">
          <AlertTriangle size={34} />
          <h1>Algo salió mal</h1>
          <p>La vista encontró un error inesperado. Podés recargar para reintentar.</p>
          <button onClick={() => window.location.reload()}>Recargar</button>
        </div>
      );
    }
    return this.props.children;
  }
}
