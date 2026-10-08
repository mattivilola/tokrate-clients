import { Component, type ReactNode } from "react";

interface Props {
  /** Shown instead of the children after one of them failed to render. */
  fallback: ReactNode | ((retry: () => void) => ReactNode);
  /** The boundary tries its children again when this changes (new data arrived). */
  resetKey?: unknown;
  children: ReactNode;
}

/**
 * Keeps a render error in one part of the window from removing the rest of it: the dashboard
 * shell, the sharing switch and settings stay on screen. The error itself is dropped, not
 * logged: it can carry the data that failed to render.
 */
export class ErrorBoundary extends Component<Props, { failed: boolean }> {
  state = { failed: false };

  static getDerivedStateFromError() {
    return { failed: true };
  }

  componentDidUpdate(previous: Props) {
    if (this.state.failed && previous.resetKey !== this.props.resetKey)
      this.setState({ failed: false });
  }

  private retry = () => this.setState({ failed: false });

  render() {
    if (!this.state.failed) return this.props.children;
    const { fallback } = this.props;
    return typeof fallback === "function" ? fallback(this.retry) : fallback;
  }
}
