from pydantic import Field, PositiveInt
from pydantic_settings import BaseSettings


class KingbaseVectorConfig(BaseSettings):
    """
    Configuration settings for KingbaseES (with vector extension)
    """

    KINGBASE_HOST: str | None = Field(
        description="Hostname or IP address of the KingbaseES server (e.g., 'localhost')",
        default=None,
    )

    KINGBASE_PORT: PositiveInt = Field(
        description="Port number on which the KingbaseES server is listening (default is 54321)",
        default=54321,
    )

    KINGBASE_USER: str | None = Field(
        description="Username for authenticating with the KingbaseES database",
        default=None,
    )

    KINGBASE_PASSWORD: str | None = Field(
        description="Password for authenticating with the KingbaseES database",
        default=None,
    )

    KINGBASE_DATABASE: str | None = Field(
        description="Name of the KingbaseES database to connect to",
        default=None,
    )

    KINGBASE_MIN_CONNECTION: PositiveInt = Field(
        description="Minimum number of connections in the KingbaseES connection pool",
        default=1,
    )

    KINGBASE_MAX_CONNECTION: PositiveInt = Field(
        description="Maximum number of connections in the KingbaseES connection pool",
        default=5,
    )
