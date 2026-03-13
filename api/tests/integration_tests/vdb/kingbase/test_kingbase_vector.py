from core.rag.datasource.vdb.kingbase.kingbase_vector import KingbaseVector, KingbaseVectorConfig
from tests.integration_tests.vdb.test_vector_store import (
    AbstractVectorTest,
    setup_mock_redis,
)


class KingbaseVectorTest(AbstractVectorTest):
    def __init__(self):
        super().__init__()
        self.vector = KingbaseVector(
            collection_name=self.collection_name,
            config=KingbaseVectorConfig(
                host="localhost",
                port=54321,
                user="system",
                password="Difyai123456",
                database="dify",
                min_connection=1,
                max_connection=5,
            ),
        )


def test_kingbase_vector(setup_mock_redis):
    KingbaseVectorTest().run_all_tests()
