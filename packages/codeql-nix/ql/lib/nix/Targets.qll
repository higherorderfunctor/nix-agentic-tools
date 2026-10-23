/** Explicit targets and recorded request outcomes, including failures. */
module Targets {
  class Target extends @nx_target {
    string getName() { nx_targets(this, _, result, _, _, _, _, _, _, _) }
    string toString() { result = this.getName() }
  }

  class RequestResult extends @nx_request {
    RequestResult() { nx_request_results(this, _, _, _) }
    Target getTarget() { nx_requests(this, result, _, _, _, _, _, _, _, _, _) }
    string getPathJson() { nx_requests(this, _, _, _, result, _, _, _, _, _, _) }
    string getFacet() { nx_requests(this, _, _, _, _, result, _, _, _, _, _) }
    string getState() { nx_request_results(this, result, _, _) }
    string getReason() { nx_request_results(this, _, result, _) }
    int getObservedCount() { nx_request_results(this, _, _, result) }
    string toString() { result = this.getTarget().getName() + ":" + this.getPathJson() }
  }
}
