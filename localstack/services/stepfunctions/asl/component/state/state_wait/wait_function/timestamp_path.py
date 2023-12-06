import datetime
from typing import Final

from localstack.services.stepfunctions.asl.component.state.state_wait.wait_function.timestamp import (
    Timestamp,
)
from localstack.services.stepfunctions.asl.component.state.state_wait.wait_function.wait_function import (
    WaitFunction,
)
from localstack.services.stepfunctions.asl.eval.environment import Environment
from localstack.services.stepfunctions.asl.utils.json_path import JSONPathUtils


class TimestampPath(WaitFunction):
    # TimestampPath
    # An absolute time to state_wait until beginning the state specified in the Next field,
    # specified using a path from the state's input data.

    def __init__(self, path: str):
        self.path: Final[str] = path

    def _get_wait_seconds(self, env: Environment) -> int:
        timestamp_str = JSONPathUtils.extract_json(self.path, env.inp)
        try:
            timestamp = datetime.datetime.strptime(timestamp_str, Timestamp.TIMESTAMP_FORMAT)
        except Exception:
            raise
            # report_error(f"The TimestampPath parameter does not reference a valid ISO-8601 extended offset date-time format string: {self.path} == {timestamp_str}")
            # state_name = env.context_object_manager.context_object["State"]["Name"]
            # env.event_history_context.source_event_id
            # raise FailureEventException(FailureEvent(
            #     error_name=StatesErrorName(typ=StatesErrorNameType.StatesRuntime),
            #     event_type=HistoryEventType.ExecutionFailed,
            #     event_details=EventDetails(
            #         executionFailedEventDetails=ExecutionFailedEventDetails(
            #             error="States.Runtime",
            #             cause=f"The TimestampPath parameter does not reference a valid ISO-8601 extended offset date-time format string: {self.path} == {timestamp_str}"
            #         )
            #     )
            # ))
        delta = timestamp - datetime.datetime.today()
        delta_sec = int(delta.total_seconds())
        return delta_sec
