"""Shared model identities and limit registrations for collection and saved snapshots."""
from typing import Annotated, Literal, Self

from pydantic import BaseModel, Field, StrictStr, StringConstraints, model_validator


Amount = Annotated[float, Field(strict=True, ge=0, allow_inf_nan=False)]
Nonempty = Annotated[StrictStr, StringConstraints(min_length=1)]
Positive = Annotated[Amount, Field(gt=0)]


class LimitValues(BaseModel):
    """Carry the capacity, routes, and role shared by input and output limits."""

    capacity: Positive
    models: Annotated[list[Nonempty], Field(min_length=1)]
    role: Literal["gate", "pace"]


class LimitSpec(LimitValues, extra="forbid"):
    """Bind a Reader window to one configured limit."""

    window: Nonempty


class Registration(BaseModel):
    """Name the Reader pool and exact windows a configuration registers."""

    limits: dict[str, LimitSpec]
    pin: Nonempty | None
    readerPool: Nonempty

    @model_validator(mode="after")
    def unique_windows(self) -> Self:
        """Refuse two limits that claim the same Reader window."""
        windows = {spec.window for spec in self.limits.values()}
        if len(windows) != len(self.limits):
            raise ValueError("duplicate-window-registration")
        return self


class Route(BaseModel):
    """Carry one configured model identity into ranking."""

    id: Nonempty
    maker: StrictStr | None
    model: Nonempty
